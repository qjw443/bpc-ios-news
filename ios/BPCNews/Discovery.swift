import Foundation
import WebKit

/// 发现层：直接向彭博 / 路透取稿，**不经过任何第三方聚合**。
///
/// 两条通道：
///   ① HTTP：官方 sitemap / RSS（彭博实测可用，一次拿 500+ 条带标题与时间）
///   ② 网页：App 内 WKWebView 打开栏目页，抽 <a> 链接（路透 sitemap 被挑战时兜底）
///
/// 每个源都会记录「成功/失败 + 条数」，显示在设置页，便于在真机上定位是哪一端不通。
final class Discovery: NSObject {

    struct Found {
        let site: Site
        let title: String
        let link: String
        let date: Date?
    }

    struct SourceStatus: Identifiable {
        let id = UUID()
        let site: String
        let name: String
        let ok: Bool
        let count: Int
        let note: String
    }

    // MARK: - 配置

    private static let uas = [
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
    ]

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = true
        c.httpAdditionalHeaders = ["Accept": "application/xml,text/xml,application/rss+xml,*/*",
                                   "Accept-Language": "en-US,en;q=0.9"]
        return URLSession(configuration: c)
    }()

    private(set) var statuses: [SourceStatus] = []

    // MARK: - 入口

    /// 拉一轮：先 HTTP，两个站各自不足 5 条时补一次网页抓取
    func poll(completion: @escaping ([Discovery.Found]) -> Void) {
        statuses = []
        let group = DispatchGroup()
        let lock = NSLock()
        var collected: [Discovery.Found] = []
        var perSite: [String: Int] = [:]

        for site in Site.allCases {
            for ep in Sources.endpoints(for: site) {
                group.enter()
                fetch(ep) { found, note in
                    lock.lock()
                    collected.append(contentsOf: found)
                    perSite[site.rawValue, default: 0] += found.count
                    self.statuses.append(SourceStatus(site: site.rawValue, name: ep.name,
                                                      ok: !found.isEmpty,
                                                      count: found.count, note: note))
                    lock.unlock()
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            var needWeb: [Site] = []
            for site in Site.allCases where (perSite[site.rawValue] ?? 0) < 5 {
                needWeb.append(site)
            }
            guard !needWeb.isEmpty else {
                completion(self.dedupe(collected))
                return
            }
            self.scrapeWeb(needWeb) { webFound in
                self.statuses.append(SourceStatus(
                    site: needWeb.map { $0.rawValue }.joined(separator: "+"),
                    name: "网页抓取兜底", ok: !webFound.isEmpty,
                    count: webFound.count, note: "站点 sitemap/RSS 不可用时启用"))
                completion(self.dedupe(collected + webFound))
            }
        }
    }

    private func dedupe(_ items: [Discovery.Found]) -> [Discovery.Found] {
        var seen = Set<String>()
        var out: [Discovery.Found] = []
        for f in items {
            let key = f.link.split(separator: "?").first.map(String.init) ?? f.link
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(f)
        }
        return out.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    // MARK: - HTTP 通道

    private func fetch(_ ep: Sources.Endpoint, attempt: Int = 0,
                       completion: @escaping ([Discovery.Found], String) -> Void) {
        guard let url = URL(string: ep.url) else {
            completion([], "URL 非法")
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 22)
        req.setValue(Self.uas[min(attempt, Self.uas.count - 1)], forHTTPHeaderField: "User-Agent")

        session.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data, err == nil, code == 200 else {
                // 401/403 换 UA 再试一次（部分站点按 UA 放行）
                if attempt == 0 && [401, 403, 429].contains(code) {
                    self.fetch(ep, attempt: 1, completion: completion)
                    return
                }
                let note = err?.localizedDescription ?? "HTTP \(code)"
                completion([], note)
                return
            }
            let found = self.parse(data, site: ep.site, kind: ep.kind)
            completion(found, found.isEmpty ? "解析为 0 条" : "\(found.count) 条")
        }.resume()
    }

    // MARK: - XML 解析（RSS / sitemap / sitemapindex 三合一）

    private func parse(_ data: Data, site: Site, kind: Sources.Kind) -> [Discovery.Found] {
        let p = FeedParser(site: site)
        let xp = XMLParser(data: data)
        xp.delegate = p
        xp.parse()
        return p.items.filter { Sources.isArticleURL($0.link, site: site) }
    }

    // MARK: - 网页通道

    private var scrapers: [WebScraper] = []

    private func scrapeWeb(_ sites: [Site], completion: @escaping ([Discovery.Found]) -> Void) {
        var results: [Discovery.Found] = []
        let group = DispatchGroup()
        for site in sites {
            for page in Sources.pages(for: site) {
                group.enter()
                let scraper = WebScraper()
                scrapers.append(scraper)
                scraper.scrape(urlString: page, site: site) { found in
                    results.append(contentsOf: found)
                    if let i = self.scrapers.firstIndex(where: { $0 === scraper }) {
                        self.scrapers.remove(at: i)
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { completion(results) }
    }
}

// MARK: - RSS / sitemap 解析器

final class FeedParser: NSObject, XMLParserDelegate {

    private let site: Site
    private(set) var items: [Discovery.Found] = []

    private var stack: [String] = []
    private var buf = ""

    // RSS 状态
    private var inItem = false
    private var rssTitle = ""
    private var rssLink = ""
    private var rssDate = ""

    // sitemap 状态
    private var inURL = false
    private var smLoc = ""
    private var smLastmod = ""
    private var smDate = ""
    private var smTitle = ""

    init(site: Site) {
        self.site = site
        super.init()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = qName ?? elementName
        stack.append(name)
        buf = ""
        if name == "item" {
            inItem = true
            rssTitle = ""; rssLink = ""; rssDate = ""
        } else if name == "url" {
            inURL = true
            smLoc = ""; smLastmod = ""; smDate = ""; smTitle = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buf += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { buf += s }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = qName ?? elementName
        let text = buf.trimmed
        defer {
            buf = ""
            if !stack.isEmpty { stack.removeLast() }
        }

        if inItem {
            switch name {
            case "title": rssTitle = text
            case "link": rssLink = text
            case "pubDate", "published", "updated": rssDate = text
            case "item":
                inItem = false
                if rssLink.count > 10, rssTitle.count > 8 {
                    items.append(Discovery.Found(site: site, title: Self.decode(rssTitle),
                                       link: rssLink,
                                       date: Self.parseDate(rssDate)))
                }
            default: break
            }
            return
        }

        if inURL {
            switch name {
            case "loc": smLoc = text
            case "lastmod": smLastmod = text
            case "news:title", "title": smTitle = text
            case "news:publication_date", "publication_date": smDate = text
            case "url":
                inURL = false
                if smLoc.count > 10 {
                    let title = smTitle.isEmpty ? Self.titleFromURL(smLoc) : Self.decode(smTitle)
                    let date = Self.parseISO(smDate.isEmpty ? smLastmod : smDate)
                    items.append(Discovery.Found(site: site, title: title, link: smLoc, date: date))
                }
            default: break
            }
        }
    }

    // MARK: 工具

    static func decode(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<![CDATA[", with: "")
                 .replacingOccurrences(of: "]]>", with: "")
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                   "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (k, v) in map { t = t.replacingOccurrences(of: k, with: v) }
        return t.trimmed
    }

    static func titleFromURL(_ url: String) -> String {
        guard let last = url.split(separator: "/").last else { return url }
        var s = String(last)
        if s.hasSuffix(".html") { s = String(s.dropLast(5)) }
        // 去掉 id 尾巴，把连字符还原成空格
        s = s.replacingOccurrences(of: "-", with: " ")
        return s.trimmed
    }

    static func parseDate(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for fmt in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm:ss Z",
                    "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ",
                    "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: s.trimmed) { return d }
        }
        return parseISO(s)
    }

    static func parseISO(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - 网页抓取（设备端兜底）

final class WebScraper: NSObject, WKNavigationDelegate {

    private var webView: WKWebView?
    private var onDone: (([Discovery.Found]) -> Void)?
    private var site: Site = .reuters
    private var finished = false

    func scrape(urlString: String, site: Site,
                done: @escaping ([Discovery.Found]) -> Void) {
        self.site = site
        self.onDone = done
        PaywallEngine.shared.prepare { [weak self] in
            guard let self = self, let url = URL(string: urlString) else {
                done([])
                return
            }
            let wv = PaywallEngine.shared.makeWebView(site: site, userAgent: Rules.chromeUA)
            wv.navigationDelegate = self
            self.webView = wv
            wv.load(PaywallEngine.shared.request(for: url, site: site))

            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                self?.finishWith([])
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.extract()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishWith([])
    }

    private func extract() {
        guard let wv = webView else { return }
        let js = """
        (function(){
          var out = [], seen = {};
          var as = document.querySelectorAll('a[href]');
          for (var i = 0; i < as.length; i++) {
            var h = as[i].href || '';
            var t = (as[i].innerText || '').trim().replace(/\\s+/g, ' ');
            if (t.length < 16) continue;
            if (seen[h]) continue;
            if (h.indexOf('bloomberg.com/news/') < 0 && h.indexOf('reuters.com/') < 0) continue;
            seen[h] = 1;
            out.push({u: h, t: t});
            if (out.length >= 40) break;
          }
          return JSON.stringify(out);
        })();
        """
        wv.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self else { return }
            var found: [Discovery.Found] = []
            if let s = result as? String, let d = s.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
                for row in arr {
                    guard let u = row["u"] as? String, let t = row["t"] as? String else { continue }
                    if !Sources.isArticleURL(u, site: self.site) { continue }
                    found.append(Discovery.Discovery.Found(site: self.site, title: t, link: u, date: Date()))
                }
            }
            self.finishWith(found)
        }
    }

    private func finishWith(_ found: [Discovery.Found]) {
        guard !finished else { return }
        finished = true
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        let cb = onDone
        onDone = nil
        cb?(found)
    }
}
