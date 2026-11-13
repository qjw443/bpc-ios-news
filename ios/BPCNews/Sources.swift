import Foundation

/// 发现源清单：全部来自**彭博 / 路透自己**，不含任何第三方聚合。
///
/// 每一项都标了来源依据（robots.txt 官方声明 / 公开 RSS 路径），便于将来核对：
///   Bloomberg robots.txt:  Sitemap: https://www.bloomberg.com/sitemaps/news/latest.xml
///   Reuters  robots.txt:  SITEMAP: https://www.reuters.com/arc/outboundfeeds/news-sitemap-index/?outputType=xml
///                         SITEMAP: https://www.reuters.com/arc/outboundfeeds/sitemap-index/?outputType=xml
///
/// 实测（2026-11-13，数据中心 IP）：
///   bloomberg latest.xml  200 / 561 条，含 news:title + news:publication_date  ✅
///   bloomberg RSS ×6      200 / 每栏 8–20 条，直链为 /news/articles/...        ✅
///   reuters 全部 sitemap  401（边缘反爬挑战）→ 走设备端 WebView 兜底           ⚠️
enum Sources {

    enum Kind {
        case rss          // <item><title><link><pubDate>
        case sitemap      // <url><loc><news:title><news:publication_date>  或 sitemapindex
    }

    struct Endpoint {
        let site: Site
        let name: String
        let url: String
        let kind: Kind
    }

    /// 彭博：sitemap 优先（一次拿 500+ 条带标题与时间），RSS 兜底
    static let bloomberg: [Endpoint] = [
        Endpoint(site: .bloomberg, name: "BBG Sitemap·latest",
                 url: "https://www.bloomberg.com/sitemaps/news/latest.xml", kind: .sitemap),
        Endpoint(site: .bloomberg, name: "BBG RSS·Markets",
                 url: "https://feeds.bloomberg.com/markets/news.rss", kind: .rss),
        Endpoint(site: .bloomberg, name: "BBG RSS·Politics",
                 url: "https://feeds.bloomberg.com/politics/news.rss", kind: .rss),
        Endpoint(site: .bloomberg, name: "BBG RSS·Tech",
                 url: "https://feeds.bloomberg.com/technology/news.rss", kind: .rss),
        Endpoint(site: .bloomberg, name: "BBG RSS·Economics",
                 url: "https://feeds.bloomberg.com/economics/news.rss", kind: .rss),
        Endpoint(site: .bloomberg, name: "BBG RSS·Industries",
                 url: "https://feeds.bloomberg.com/industries/news.rss", kind: .rss),
        Endpoint(site: .bloomberg, name: "BBG RSS·Crypto",
                 url: "https://feeds.bloomberg.com/crypto/news.rss", kind: .rss),
    ]

    /// 路透：官方 sitemap（设备上可能放行），失败则走页面抓取
    static let reuters: [Endpoint] = [
        Endpoint(site: .reuters, name: "RTR News Sitemap",
                 url: "https://www.reuters.com/arc/outboundfeeds/news-sitemap-index/?outputType=xml",
                 kind: .sitemap),
        Endpoint(site: .reuters, name: "RTR Sitemap Index",
                 url: "https://www.reuters.com/arc/outboundfeeds/sitemap-index/?outputType=xml",
                 kind: .sitemap),
    ]

    /// 路透网页兜底：用 App 内 WKWebView 打开栏目页，抽文章链接
    static let reutersPages = [
        "https://www.reuters.com/world/",
        "https://www.reuters.com/business/",
        "https://www.reuters.com/markets/",
        "https://www.reuters.com/technology/",
    ]

    /// 彭博网页兜底（sitemap + RSS 都失败时）
    static let bloombergPages = [
        "https://www.bloomberg.com/markets",
        "https://www.bloomberg.com/technology",
        "https://www.bloomberg.com/politics",
    ]

    static func endpoints(for site: Site) -> [Endpoint] {
        site == .bloomberg ? bloomberg : reuters
    }

    static func pages(for site: Site) -> [String] {
        site == .bloomberg ? bloombergPages : reutersPages
    }

    /// 各站文章路径前缀（用于过滤栏目页/标签页/视频页）
    static func isArticleURL(_ url: String, site: Site) -> Bool {
        let u = url.split(separator: "?").first.map(String.init) ?? url
        switch site {
        case .bloomberg:
            return u.contains("bloomberg.com/news/articles/")
                || u.contains("bloomberg.com/news/features/")
                || u.contains("bloomberg.com/opinion/articles/")
        case .reuters:
            guard u.contains("reuters.com/") else { return false }
            let path = u.replacingOccurrences(of: "https://www.reuters.com", with: "")
                          .replacingOccurrences(of: "https://reuters.com", with: "")
            let segs = path.split(separator: "/").map(String.init)
            guard segs.count >= 2 else { return false }
            // 新版：/world/…/  /business/…/   旧版：/article/<section>/<slug>/
            if segs[0] == "article" { return segs.count >= 3 }
            let sections = ["world", "business", "markets", "technology", "legal",
                            "sustainability", "breakingviews", "sports", "science",
                            "health", "commentary", "investigates", "graphics"]
            return sections.contains(segs[0])
        }
    }
}
