import Foundation

/// 三级翻译服务：在线逐句 → 离线词典。与视图生命周期完全解耦。
///
/// 为什么不用 Apple 端上翻译做主力：
/// `TranslationSession` 依赖 SwiftUI 的 `translationTask` 生命周期，一旦语言包缺失 / 会话被回收，
/// 回调就不来，整条翻译链会静默卡死（这正是"标题一直是英文"的根因）。
/// 这里改为「发请求-收结果」的普通异步服务，可超时、可重试、可降级。
final class TranslateService {

    static let shared = TranslateService()

    enum Source: String { case online = "在线", dict = "词典", none = "未译" }

    private let lock = NSLock()
    private var cache: [String: String] = [:]        // 原文 → 译文（内存）
    private var diskCache: [String: String] = [:]    // 原文 → 译文（落盘，重启仍在）
    private var inFlight = Set<String>()

    init() {
        if let d = try? Data(contentsOf: Self.cacheURL),
           let m = try? JSONDecoder().decode([String: String].self, from: d) {
            // 清掉旧版本写进来的 URL 编码脏译文（%20 / %2C 等）
            let clean = m.filter { !$0.value.contains("%20") && !$0.value.contains("%2C")
                && !$0.value.contains("%3A") }
            diskCache = clean
            if clean.count != m.count {
                try? Data().write(to: Self.cacheURL)   // 丢弃整个旧缓存，重建
                diskCache = [:]
            }
        }
    }

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("translate_cache.json")
    }

    private func persist() {
        let snapshot = diskCache
        DispatchQueue.global(qos: .utility).async {
            if let d = try? JSONEncoder().encode(snapshot) {
                try? d.write(to: Self.cacheURL)
            }
        }
    }

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 12
        c.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: c)
    }()

    /// 翻译一组文本（保持顺序）。任一失败则该项回退词典。
    /// 统一净化译文：解 URL 编码、压空白、去服务商告警
    private static func sanitize(_ raw: String) -> String {
        var t = raw
        if t.contains("%20") || t.contains("%2C") || t.contains("%3A") || t.contains("%E") {
            t = t.removingPercentEncoding ?? t
        }
        t = t.replacingOccurrences(of: "+", with: " ")
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 归一化缓存键：压空白、去首尾标点差异，提高命中率
    private static func key(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
         .trimmingCharacters(in: CharacterSet(charactersIn: " \"\u{201c}\u{201d}\"'"))
    }

    func translate(_ texts: [String], completion: @escaping ([String], Source) -> Void) {
        guard !texts.isEmpty else { completion([], .none); return }

        var out = [String](repeating: "", count: texts.count)
        var pending: [Int] = []
        lock.lock()
        for (i, t) in texts.enumerated() {
            let k = Self.key(t)
            if let hit = cache[k], !hit.isEmpty { out[i] = hit }
            else if let hit = diskCache[k], !hit.isEmpty { out[i] = hit; cache[k] = hit }
            else { pending.append(i) }
        }
        lock.unlock()

        if pending.isEmpty {
            completion(out, .online)
            return
        }

        let group = DispatchGroup()
        let sem = DispatchSemaphore(value: 8)
        var onlineHit = 0
        let hitLock = NSLock()

        // 整体超时兜底：无论网络如何，25 秒内一定回调一次
        var finished = false
        let doneLock = NSLock()
        let overallTimeout = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            doneLock.lock()
            if finished { doneLock.unlock(); return }
            finished = true
            doneLock.unlock()
            var out2 = out
            for i in texts.indices where out2[i].isEmpty {
                let zh = Dict.translate(texts[i])
                out2[i] = (TextQuality.isTranslatedLoose(zh) ? zh : texts[i])
            }
            completion(out2, .dict)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: overallTimeout)

        for i in pending {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { group.leave(); return }
                sem.wait()
                self.fetchOnline(texts[i]) { zh in
                    defer { sem.signal(); group.leave() }
                    if let zh = zh, !zh.isEmpty {
                        out[i] = zh
                        let k = Self.key(texts[i])
                        self.lock.lock()
                        self.cache[k] = zh
                        self.diskCache[k] = zh
                        self.lock.unlock()
                        self.persist()
                        hitLock.lock(); onlineHit += 1; hitLock.unlock()
                    }
                }
            }
        }

        group.notify(queue: .main) {
            doneLock.lock()
            if finished { doneLock.unlock(); return }
            finished = true
            doneLock.unlock()
            overallTimeout.cancel()
            var usedDict = false
            for i in texts.indices where out[i].isEmpty {
                let zh = Dict.translate(texts[i])
                // 词典只要译出中文就用（哪怕中英混排）——否则在线端点不可达时标题会永远是英文
                if TextQuality.isTranslatedLoose(zh), zh != texts[i] {
                    out[i] = zh
                    usedDict = true
                } else {
                    out[i] = texts[i]
                }
            }
            completion(out, onlineHit > 0 ? .online : (usedDict ? .dict : .none))
        }
    }

    /// 备用端点：MyMemory（Google 端点被墙/限流时兜底，免费无 Key）
    private func fetchMyMemory(_ text: String, done: @escaping (String?) -> Void) {
        guard text.count <= 480 else { done(nil); return }
        let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://api.mymemory.translated.net/get?q=\(q)&langpair=en|zh-CN") else {
            done(nil)
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        session.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rd = obj["responseData"] as? [String: Any],
                  let raw = rd["translatedText"] as? String,
                  !raw.isEmpty else {
                done(nil)
                return
            }
            if raw.lowercased().contains("mymemory warning") || raw.contains("QUERY LENGTH LIMIT") {
                done(nil)
                return
            }
            let t = Self.sanitize(raw)
            done(t.isEmpty ? nil : t)
        }.resume()
    }

    /// 单句在线翻译（免费公共端点，无需 Key；需网络可达）
    private func fetchOnline(_ text: String, done: @escaping (String?) -> Void) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > 1, t.count < 900 else { done(nil); return }
        var comps = URLComponents(string: "https://translate.googleapis.com/translate_a/single")
        comps?.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: "zh-CN"),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: t),
        ]
        guard let url = comps?.url else { done(nil); return }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
                     + "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")

        session.dataTask(with: req) { data, resp, _ in
            guard let data = data, (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let segs = json.first as? [[Any]] else {
                // 备用端点：MyMemory（免费无 key，单句上限 500 字符）
                self.fetchMyMemory(t, done: done)
                return
            }
            var parts: [String] = []
            for seg in segs {
                if let s = seg.first as? String { parts.append(s) }
            }
            let zh = Self.sanitize(parts.joined())
            done(zh.isEmpty ? nil : zh)
        }.resume()
    }
}
