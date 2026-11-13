import Foundation

/// 列表缩略图：彭博的 RSS/sitemap 都不带图片字段（实测只有 title/description/link/creator/pubDate），
/// 所以只能从文章页取 `og:image`。策略：
///   · 只补「还没有图」的最新 N 条（默认 12 条），避免一次发几十个请求
///   · 并发 3，单条 12s 超时，失败即跳过（不重试、不中继，缩略图不值得）
///   · 结果写回本地库，之后不再重复请求
final class ThumbnailLoader {

    static let shared = ThumbnailLoader()

    private var inFlight = Set<String>()
    private let lock = NSLock()
    var onUpdate: (() -> Void)?

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 12
        c.httpAdditionalHeaders = [
            "User-Agent": Rules.googlebotUA,
            "Accept": "text/html,application/xhtml+xml,*/*",
            "Accept-Language": "en-US,en;q=0.9",
        ]
        return URLSession(configuration: c)
    }()

    private let semaphore = DispatchSemaphore(value: 3)

    /// 给缺少缩略图的条目补图（按时间倒序取最新）
    func fill(_ items: [FeedItem], limit: Int = 12) {
        let todo = items.filter { $0.imageURL == nil && !$0.url.isEmpty }.prefix(limit)
        for item in todo {
            lock.lock()
            if inFlight.contains(item.id) {
                lock.unlock()
                continue
            }
            inFlight.insert(item.id)
            lock.unlock()

            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else { return }
                self.semaphore.wait()
                self.fetchOGImage(item) { url in
                    self.semaphore.signal()
                    self.lock.lock()
                    self.inFlight.remove(item.id)
                    self.lock.unlock()
                    guard let url = url else { return }
                    Library.shared.setImage(item.id, url)
                    DispatchQueue.main.async { self.onUpdate?() }
                }
            }
        }
    }

    private func fetchOGImage(_ item: FeedItem, done: @escaping (String?) -> Void) {
        guard let u = URL(string: item.url) else { done(nil); return }
        var req = URLRequest(url: u, timeoutInterval: 12)
        if item.site == .reuters {
            req.setValue(Rules.chromeUA, forHTTPHeaderField: "User-Agent")
            req.setValue("https://www.reuters.com/", forHTTPHeaderField: "Referer")
        }
        session.dataTask(with: req) { data, resp, _ in
            guard let data = data,
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else {
                done(nil)
                return
            }
            done(Self.parseImageURL(html, site: item.site))
        }.resume()
    }

    /// 四级回退取图：og:image → JSON-LD → 站点 CDN 特征 → <img> 启发式。
    /// 之所以要四级：实测不少新闻站（含 BBC/Guardian 的某些版面）根本没有 og:image，
    /// 只认一个 meta 会导致缩略图大面积空窗。
    static func parseImageURL(_ html: String, site: Site) -> String? {
        if let s = firstMatch(html, patterns: [
            #"<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']"#,
            #"<meta[^>]+name=["']twitter:image["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+name=["']twitter:image["']"#,
        ]) { return s }

        // JSON-LD（Bloomberg/Reuters 都内嵌结构化数据）
        if let s = firstMatch(html, patterns: [
            #""image"\s*:\s*\[\s*\{[^}]*?"url"\s*:\s*"([^"]+)""#,
            #""image"\s*:\s*\[\s*"([^"]+)""#,
            #""image"\s*:\s*"([^"]+)""#,
            #""thumbnailUrl"\s*:\s*"([^"]+)""#,
        ]) { return s }

        switch site {
        case .bloomberg:
            if let s = firstMatch(html, patterns: [
                #"(https://assets\.bwbx\.io/images/[^"'\s\\]+?\.(?:jpg|jpeg|png|webp))"#,
            ]) { return s }
        case .reuters:
            if let s = firstMatch(html, patterns: [
                #"(https://www\.reuters\.com/resizer/[^"'\s\\]+?\.(?:jpg|jpeg|png|webp))"#,
                #"(https://cloudfront-us-east-2\.images\.arcpublishing\.com/reuters/[^"'\s\\]+?\.(?:jpg|jpeg|png|webp))"#,
            ]) { return s }
        }

        // 最后兜底：正文里第一张“像图”的图
        if let s = firstMatch(html, patterns: [
            #"<img[^>]+src=["'](https?://[^"']+?\.(?:jpg|jpeg|png|webp))["']"#,
            #"<img[^>]+data-src=["'](https?://[^"']+?\.(?:jpg|jpeg|png|webp))["']"#,
        ], reject: ["logo", "icon", "avatar", "sprite", "favicon", "1x1", "pixel"]) {
            return s
        }
        return nil
    }

    private static func firstMatch(_ html: String, patterns: [String],
                                   reject: [String] = []) -> String? {
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            for m in re.matches(in: html, options: [], range: range) where m.numberOfRanges > 1 {
                guard let r = Range(m.range(at: 1), in: html) else { continue }
                var s = String(html[r])
                if s.hasPrefix("//") { s = "https:" + s }
                guard s.hasPrefix("http") else { continue }
                let low = s.lowercased()
                if reject.contains(where: { low.contains($0) }) { continue }
                return s
            }
        }
        return nil
    }
}
