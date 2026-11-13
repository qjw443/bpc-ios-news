import Foundation
import WebKit

/// 付费墙引擎：在 App 内部用 WKWebView 完成「拦截付费墙脚本 → 清 DOM → 取正文」。
/// 这是 BPC 扩展逻辑在 iOS 上的等价实现，不需要任何服务器。
final class PaywallEngine: NSObject {

    static let shared = PaywallEngine()

    private var lists: [String: WKContentRuleList] = [:]
    private var compiling = false
    private var waiting: [() -> Void] = []

    // MARK: - 规则编译（一次性，之后复用）

    func prepare(_ done: @escaping () -> Void) {
        DispatchQueue.main.async {
            if self.lists.count >= Site.allCases.count {
                done()
                return
            }
            self.waiting.append(done)
            guard !self.compiling else { return }
            self.compiling = true
            self.compile(Array(Site.allCases), index: 0)
        }
    }

    private func compile(_ sites: [Site], index: Int) {
        guard index < sites.count else {
            compiling = false
            let cbs = waiting
            waiting = []
            cbs.forEach { $0() }
            return
        }
        let site = sites[index]
        let id = "bpc-\(site.rawValue)"
        let json = Rules.blockListJSON(for: site)
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: id,
            encodedContentRuleList: json
        ) { list, err in
            if let list = list {
                self.lists[id] = list
            } else if let err = err {
                print("[rules] compile failed \(site.rawValue): \(err.localizedDescription)")
            }
            self.compile(sites, index: index + 1)
        }
    }

    var compiledCount: Int { lists.count }

    // MARK: - 配置

    func makeConfiguration(site: Site) -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()          // 每次都是全新会话 = 清 cookie 的等价物
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true

        let uc = cfg.userContentController
        if let list = lists["bpc-\(site.rawValue)"] {
            uc.add(list)                                  // ① 拦付费墙 JS
        }
        uc.addUserScript(WKUserScript(source: Rules.storageJS,
                                      injectionTime: .atDocumentStart,
                                      forMainFrameOnly: false))   // ② 清 localStorage
        uc.addUserScript(WKUserScript(source: Rules.cleanupJS,
                                      injectionTime: .atDocumentEnd,
                                      forMainFrameOnly: false))   // ③ 清 DOM / 去模糊
        return cfg
    }

    func makeWebView(site: Site, userAgent: String) -> WKWebView {
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                           configuration: makeConfiguration(site: site))
        wv.customUserAgent = userAgent
        wv.isOpaque = true
        wv.backgroundColor = .black
        return wv
    }

    /// 请求头：Referer + 语言（对应 BPC 的 modifyHeaders）
    func request(for url: URL, site: Site) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 40)
        r.setValue("https://www.google.com/", forHTTPHeaderField: "Referer")
        r.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        r.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                   forHTTPHeaderField: "Accept")
        return r
    }

    /// 手动清 cookie（设置页按钮用）。
    /// 注意：抓取用的上下文都是 .nonPersistent()，每次全新会话，本身不残留；
    /// 这里清的是默认仓里的历史 cookie（例如以前用 Safari 打开过同样的站）。
    func wipeAllCookies(_ done: @escaping () -> Void) {
        let store = WKWebsiteDataStore.default()
        store.httpCookieStore.getAllCookies { cookies in
            let group = DispatchGroup()
            for c in cookies {
                group.enter()
                store.httpCookieStore.delete(c) { group.leave() }
            }
            group.notify(queue: .main) { done() }
        }
    }
}

// MARK: - 抓取结果

struct RawBlock: Decodable {
    let type: String
    let text: String?
    let src: String?
}

struct RawExtract: Decodable {
    let title: String?
    let blocks: [RawBlock]?
    let summary: [String]?
    let audio: String?
    let via: String?
    let walls: [String]?
}

/// 离屏 WKWebView 抓取器：加载文章 → 等渲染 → 执行提取 JS → 得到 blocks
final class ArticleFetcher: NSObject, WKNavigationDelegate {

    enum FetchError: LocalizedError {
        case loadFailed(String)
        case emptyBlocks(Int)
        case timeout

        var errorDescription: String? {
            switch self {
            case .loadFailed(let s): return "页面加载失败：\(s)"
            case .emptyBlocks(let n): return "只取到 \(n) 段，页面可能改版或被拦"
            case .timeout: return "加载超时"
            }
        }
    }

    private var webView: WKWebView?
    private var onSuccess: ((Article) -> Void)?
    private var onFail: ((Error) -> Void)?
    private var site: Site = .bloomberg
    private var articleURL: URL!
    private var startedAt = Date()
    private var archiveTried = false
    private var botMode = false
    private var lastFinalURL = ""

    private var hardTimeout: DispatchWorkItem?

    func start(url: URL, site: Site, botMode: Bool,
               onSuccess: @escaping (Article) -> Void,
               onFail: @escaping (Error) -> Void) {
        self.articleURL = url
        self.site = site
        self.botMode = botMode
        self.onSuccess = onSuccess
        self.onFail = onFail
        self.startedAt = Date()

        PaywallEngine.shared.prepare { [weak self] in
            guard let self = self else { return }
            let ua = botMode ? Rules.googlebotUA : Rules.chromeUA
            let wv = PaywallEngine.shared.makeWebView(site: site, userAgent: ua)
            wv.navigationDelegate = self
            self.webView = wv

            let work = DispatchWorkItem { [weak self] in
                self?.finish(.failure(FetchError.timeout))
            }
            self.hardTimeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: work)

            wv.load(PaywallEngine.shared.request(for: url, site: site))
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastFinalURL = webView.url?.absoluteString ?? articleURL.absoluteString
        // 给付费墙脚本一点时间跑，再清理并取文
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.extract()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(FetchError.loadFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        finish(.failure(FetchError.loadFailed(error.localizedDescription)))
    }

    // MARK: 提取

    private func extract() {
        guard let wv = webView else { return }
        let js = archiveTried ? Rules.extractArchive : Rules.extractJS(for: site)
        wv.evaluateJavaScript(js) { [weak self] result, err in
            guard let self = self else { return }
            if let err = err {
                print("[extract] js error: \(err.localizedDescription)")
            }
            let json = (result as? String) ?? ""
            let raw = Self.decode(json)
            let blocks = (raw?.blocks ?? []).compactMap { b -> Block? in
                let t = (b.text ?? "").trimmed
                if b.type == "img" {
                    guard let src = b.src, !src.isEmpty else { return nil }
                    return Block(type: "img", text: t, src: src)
                }
                return t.isEmpty && b.type != "hr" ? nil : Block(type: b.type, text: t, src: b.src)
            }

            if blocks.count < 3 && !self.archiveTried {
                self.archiveFallback()
                return
            }
            if blocks.count < 3 {
                self.finish(.failure(FetchError.emptyBlocks(blocks.count)))
                return
            }

            var art = Article(id: Hash.short(self.articleURL.absoluteString),
                              site: self.site,
                              url: self.articleURL.absoluteString,
                              title: (raw?.title ?? "").trimmed)
            art.blocks = blocks
            art.brief = raw?.summary ?? []
            art.audio = raw?.audio
            art.fetchedAt = Int(Date().timeIntervalSince1970)
            art.fromArchive = self.archiveTried
            art.via = (raw?.via?.isEmpty == false) ? raw!.via!
                       : (self.archiveTried ? "archive" : "unknown")
            art.walls = raw?.walls ?? []

            // 没标题就用正文首段兜底
            if art.title.isEmpty, let first = blocks.first(where: { $0.type == "p" }) {
                art.title = String(first.text.prefix(80))
            }
            Diagnostics.shared.record(site: self.site.rawValue,
                                      url: self.articleURL.absoluteString,
                                      finalURL: self.lastFinalURL.isEmpty
                                          ? self.articleURL.absoluteString : self.lastFinalURL,
                                      via: art.via, blocks: blocks.count, walls: art.walls,
                                      ms: Int(Date().timeIntervalSince(self.startedAt) * 1000),
                                      ok: true)
            self.finish(.success(art))
        }
    }

    private func archiveFallback() {
        guard let wv = webView else { return }
        archiveTried = true
        guard let a = URL(string: "https://archive.ph/newest/" + articleURL.absoluteString) else {
            finish(.failure(FetchError.emptyBlocks(0)))
            return
        }
        wv.load(PaywallEngine.shared.request(for: a, site: site))
    }

    private static func decode(_ json: String) -> RawExtract? {
        guard let d = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RawExtract.self, from: d)
    }

    private func finish(_ result: Result<Article, Error>) {
        hardTimeout?.cancel()
        hardTimeout = nil
        let ok = onSuccess
        let bad = onFail
        onSuccess = nil
        onFail = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        switch result {
        case .success(let a):
            ok?(a)
        case .failure(let e):
            Diagnostics.shared.record(site: site.rawValue,
                                      url: articleURL.absoluteString,
                                      finalURL: lastFinalURL.isEmpty
                                          ? articleURL.absoluteString : lastFinalURL,
                                      via: archiveTried ? "archive" : "none", blocks: 0,
                                      walls: [], ms: Int(Date().timeIntervalSince(startedAt) * 1000),
                                      ok: false, note: e.localizedDescription)
            bad?(e)
        }
    }
}
