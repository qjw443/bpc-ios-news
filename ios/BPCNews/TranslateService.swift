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
    private var cache: [String: String] = [:]        // 原文 → 译文
    private var inFlight = Set<String>()

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 12
        c.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: c)
    }()

    /// 翻译一组文本（保持顺序）。任一失败则该项回退词典。
    func translate(_ texts: [String], completion: @escaping ([String], Source) -> Void) {
        guard !texts.isEmpty else { completion([], .none); return }

        var out = [String](repeating: "", count: texts.count)
        var pending: [Int] = []
        lock.lock()
        for (i, t) in texts.enumerated() {
            if let hit = cache[t], !hit.isEmpty { out[i] = hit } else { pending.append(i) }
        }
        lock.unlock()

        if pending.isEmpty {
            completion(out, .online)
            return
        }

        let group = DispatchGroup()
        let sem = DispatchSemaphore(value: 4)
        var onlineHit = 0
        let hitLock = NSLock()

        for i in pending {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { group.leave(); return }
                sem.wait()
                self.fetchOnline(texts[i]) { zh in
                    defer { sem.signal(); group.leave() }
                    if let zh = zh, !zh.isEmpty {
                        out[i] = zh
                        self.lock.lock(); self.cache[texts[i]] = zh; self.lock.unlock()
                        hitLock.lock(); onlineHit += 1; hitLock.unlock()
                    }
                }
            }
        }

        group.notify(queue: .main) {
            var usedDict = false
            for i in texts.indices where out[i].isEmpty {
                let zh = Dict.translate(texts[i])
                if !zh.isEmpty, zh != texts[i] {
                    out[i] = zh
                    usedDict = true
                } else {
                    out[i] = texts[i]
                }
            }
            completion(out, onlineHit > 0 ? .online : (usedDict ? .dict : .none))
        }
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
                done(nil)
                return
            }
            var parts: [String] = []
            for seg in segs {
                if let s = seg.first as? String { parts.append(s) }
            }
            let zh = parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            done(zh.isEmpty ? nil : zh)
        }.resume()
    }
}
