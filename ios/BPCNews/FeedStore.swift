import Foundation
import UserNotifications
import UIKit

/// 编排层：发现 → 入库 → 抓正文（App 内 WKWebView 绕过付费墙）→ 本地通知
final class FeedStore: ObservableObject {

    static let shared = FeedStore()

    @Published var items: [FeedItem] = []
    @Published var loading = false
    @Published var status: String = ""
    @Published var lastError: String = ""

    private let discovery = Discovery()
    private var fetchers: [String: ArticleFetcher] = [:]
    private var busy = false
    private let lastCheckKey = "last_discovery_ts"

    /// 用来解析 Google News 跳转链接
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = true
        c.httpAdditionalHeaders = ["User-Agent": Rules.chromeUA,
                                   "Accept-Language": "en-US,en;q=0.9"]
        return URLSession(configuration: c)
    }()

    // MARK: - 启动

    func bootstrap() {
        Library.shared.load()
        items = Library.shared.items
        status = "规则编译中…"
        PaywallEngine.shared.prepare { [weak self] in
            self?.status = "规则就绪（\(PaywallEngine.shared.compiledCount) 条）"
        }
    }

    // MARK: - 发现最新

    func refresh(notify: Bool = false, completion: (() -> Void)? = nil) {
        guard !busy else { completion?(); return }
        busy = true
        DispatchQueue.main.async { self.loading = true; self.lastError = "" }

        discovery.poll { [weak self] found in
            guard let self = self else { return }
            let enabled = Settings.enabledSites
            var mapped: [FeedItem] = []
            for f in found where enabled.contains(f.site.rawValue) {
                let title = Self.cleanTitle(f.title)
                let id = Hash.short(f.link + "|" + title)
                var item = FeedItem(id: id,
                                    site: f.site,
                                    title: title,
                                    url: f.link,
                                    ts: Int((f.date ?? Date()).timeIntervalSince1970))
                // 词典模式：列表标题当场中文化，不用等正文
                if Settings.zhMode == "dict" {
                    item.titleZh = Dict.translate(title)
                }
                mapped.append(item)
            }
            let fresh = Library.shared.merge(mapped)
            DispatchQueue.main.async {
                self.items = Library.shared.items
                self.loading = false
                self.busy = false
                self.status = "发现 \(mapped.count) 条 / 新增 \(fresh.count) 条"
                UserDefaults.standard.set(Int(Date().timeIntervalSince1970), forKey: self.lastCheckKey)
            }
            if notify && !fresh.isEmpty { self.notifyNew(fresh) }
            completion?()

            // 自动预热最新几条的正文，点开即读
            if Settings.autoFetch {
                for item in fresh.prefix(3) {
                    self.fetch(item: item, silent: true)
                }
            }
        }
    }

    // MARK: - 抓正文（App 内绕过付费墙）

    func fetch(item: FeedItem, silent: Bool = false, completion: ((Article?) -> Void)? = nil) {
        if let cached = Library.shared.article(for: item.id), cached.blocks.count >= 3 {
            completion?(cached)
            return
        }
        guard fetchers[item.id] == nil else { completion?(nil); return }

        // 关键：Google News 的 /rss/articles/... 是跳转页，必须先解析成真实文章地址，
        // 否则 WebView 打开的是 Google 中间页，永远提不到正文。
        if item.url.contains("news.google.com") {
            status = "解析原文链接…"
            Discovery.resolve(item.url, session: session) { [weak self] resolved in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    // 解析不出来也没关系：Google 那个页面靠 JS 跳转，
                    // 交给 WKWebView 执行（PaywallEngine 里会监视跳转）。
                    if resolved != item.url, resolved.hasPrefix("http") {
                        Library.shared.updateURL(item.id, to: resolved)
                        self.items = Library.shared.items
                        var it = item
                        it.url = resolved
                        self.startFetch(item: it, silent: silent, completion: completion)
                    } else {
                        self.status = "经 Google 跳转打开…"
                        self.startFetch(item: item, silent: silent, completion: completion)
                    }
                }
            }
            return
        }
        startFetch(item: item, silent: silent, completion: completion)
    }

    private func startFetch(item: FeedItem, silent: Bool,
                            completion: ((Article?) -> Void)?) {
        guard let url = URL(string: item.url) else { completion?(nil); return }
        let fetcher = ArticleFetcher()
        fetchers[item.id] = fetcher

        func run(botMode: Bool) {
            fetcher.start(url: url, site: item.site, botMode: botMode, onSuccess: { [weak self] art in
                guard let self = self else { return }
                var a = art
                a.id = item.id
                Library.shared.markFetched(item.id, article: a)
                self.fetchers.removeValue(forKey: item.id)
                DispatchQueue.main.async {
                    self.items = Library.shared.items
                    if !silent { self.status = "已取稿：\(a.blocks.count) 段 · \(a.via)" }
                }
                completion?(a)
            }, onFail: { [weak self] err in
                guard let self = self else { return }
                if !botMode {
                    // 真 Chrome 指纹失手 → 退 Googlebot 模式再来一次
                    run(botMode: true)
                    return
                }
                self.fetchers.removeValue(forKey: item.id)
                DispatchQueue.main.async {
                    self.lastError = err.localizedDescription
                    self.status = "取稿失败"
                }
                completion?(nil)
            })
        }
        run(botMode: false)
    }

    // MARK: - 本地通知（无 APNs，全部在设备上）

    private func notifyNew(_ fresh: [FeedItem]) {
        let content = UNMutableNotificationContent()
        if fresh.count == 1 {
            content.title = fresh[0].titleZh.isEmpty ? fresh[0].title : fresh[0].titleZh
            content.body = fresh[0].site.label + " · 刚刚"
        } else {
            content.title = "财经速递 · \(fresh.count) 条新消息"
            content.body = fresh.prefix(2).map { $0.title }.joined(separator: "／")
        }
        content.sound = .default
        content.userInfo = ["itemId": fresh[0].id]
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    // MARK: - 工具

    static func cleanTitle(_ t: String) -> String {
        var s = t.trimmed
        for suffix in [" - Bloomberg.com", " - Bloomberg", " - Reuters", " | Reuters",
                       " - Reuters.com", " | Bloomberg"] {
            if s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
        }
        return s.trimmed
    }

    var pendingCount: Int {
        items.filter { !$0.fetched }.count
    }
}
