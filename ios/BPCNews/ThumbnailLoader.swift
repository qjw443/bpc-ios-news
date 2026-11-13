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
            done(Self.parseOGImage(html, site: item.site))
        }.resume()
    }

    /// 解析 og:image（属性顺序两种都要支持），拿不到再退回 twitter:image
    static func parseOGImage(_ html: String, site: Site) -> String? {
        let patterns = [
            #"<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']"#,
            #"<meta[^>]+name=["']twitter:image["'][^>]+content=["']([^"']+)["']"#,
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
               let m = re.firstMatch(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)),
               m.numberOfRanges > 1,
               let r = Range(m.range(at: 1), in: html) {
                var s = String(html[r])
                if s.hasPrefix("//") { s = "https:" + s }
                if s.hasPrefix("http") { return s }
            }
        }
        return nil
    }
}
