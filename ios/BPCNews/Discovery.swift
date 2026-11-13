import Foundation

/// 应用内新闻发现：拉 Google News RSS（已验证可用，分钟级刷新）+ 站点 sitemap 兜底。
/// 全部在设备上完成，不经过任何自建服务器。
final class Discovery: NSObject, XMLParserDelegate {

    struct Found {
        let site: Site
        let title: String
        let link: String
        let date: Date?
    }

    /// 主源：Google News 的 site: 检索（when:2h 保证只拿最近的）
    private let feeds: [(Site, String)] = [
        (.bloomberg, "https://news.google.com/rss/search?q=site%3Abloomberg.com+when%3A2h&hl=en-US&gl=US&ceid=US%3Aen"),
        (.reuters,   "https://news.google.com/rss/search?q=site%3Areuters.com+when%3A2h&hl=en-US&gl=US&ceid=US%3Aen"),
    ]

    private var currentSite: Site = .bloomberg
    private var parser: XMLParser?
    private var inItem = false
    private var bufTitle = ""
    private var bufLink = ""
    private var bufDate = ""
    private var bufText = ""
    private var collected: [Found] = []

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = true
        c.httpAdditionalHeaders = [
            "User-Agent": Rules.chromeUA,
            "Accept-Language": "en-US,en;q=0.9",
        ]
        return URLSession(configuration: c)
    }()

    /// 抓一轮，返回所有条目（是否新由 Library 判重）
    func poll(_ done: @escaping ([Found]) -> Void) {
        var results: [Found] = []
        let group = DispatchGroup()
        let lock = NSLock()

        for (site, urlStr) in feeds {
            guard let url = URL(string: urlStr) else { continue }
            group.enter()
            let task = session.dataTask(with: url) { data, _, err in
                defer { group.leave() }
                guard let data = data, err == nil else {
                    print("[discovery] \(site.rawValue) failed: \(err?.localizedDescription ?? "no data")")
                    return
                }
                let items = Self.parseRSS(data, site: site)
                lock.lock()
                results.append(contentsOf: items)
                lock.unlock()
            }
            task.resume()
        }

        group.notify(queue: .main) {
            done(results.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) })
        }
    }

    // MARK: - RSS 解析

    private static func parseRSS(_ data: Data, site: Site) -> [Found] {
        let d = Discovery()
        d.currentSite = site
        let p = XMLParser(data: data)
        p.delegate = d
        p.parse()
        return d.collected
    }

    // XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        bufText = ""
        if elementName == "item" {
            inItem = true
            bufTitle = ""
            bufLink = ""
            bufDate = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        bufText += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { bufText += s }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        guard inItem else { return }
        switch elementName {
        case "title": bufTitle = bufText
        case "link": bufLink = bufText
        case "pubDate": bufDate = bufText
        case "item":
            inItem = false
            let t = bufTitle.trimmed
            let l = bufLink.trimmed
            if t.count > 8, l.hasPrefix("http") {
                collected.append(Found(site: currentSite,
                                       title: t,
                                       link: l,
                                       date: Self.parseDate(bufDate)))
            }
        default: break
        }
        bufText = ""
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let d = f.date(from: s.trimmed) { return d }
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.date(from: s.trimmed)
    }

    // MARK: - 链接解析

    /// Google News 的 CBMi... 跳转链接 → 真实文章 URL（先跟 302，最后放弃则返回原链接）
    static func resolve(_ link: String, session: URLSession, done: @escaping (String) -> Void) {
        guard link.contains("news.google.com"),
              let url = URL(string: link) else {
            done(link)
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(Rules.chromeUA, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: req) { _, resp, _ in
            if let final = resp?.url?.absoluteString,
               !final.contains("news.google.com") {
                done(final)
            } else {
                done(link)   // 交给 WKWebView 自己跳转
            }
        }.resume()
    }
}
