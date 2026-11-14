import Foundation
import WebKit

/// 付费墙引擎：在 App 内部用 WKWebView 完成「拦截付费墙脚本 → 清 DOM → 取正文」。
/// 这是 BPC 扩展逻辑在 iOS 上的等价实现，不需要任何服务器。
final class PaywallEngine: NSObject {

    static let shared = PaywallEngine()

    private var lists: [String: WKContentRuleList] = [:]
    private var compiling = false
    private var attemptedSites = Set<String>()
    private var waiting: [() -> Void] = []

    // MARK: - 规则编译（一次性，之后复用）

    func prepare(_ done: @escaping () -> Void) {
        DispatchQueue.main.async {
            if self.attemptedSites.count >= Site.allCases.count {
                done()
                return
            }
            self.waiting.append(done)
            guard !self.compiling else { return }
            self.compiling = true
            for st in Site.allCases { self.attemptedSites.insert(st.rawValue) }
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
        // 持久会话：复用 cf_clearance / 站点同意 cookie，避免每篇都重新过验证（更快，也更像真人）
        cfg.websiteDataStore = .default()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true

        let uc = cfg.userContentController
        if let list = lists["bpc-\(site.rawValue)"] {
            uc.add(list)                                  // ① 拦付费墙 JS
        }
        // ② 反检测指纹补丁：最早时机注入，先于站点任何脚本
        uc.addUserScript(WKUserScript(source: Stealth.script,
                                      injectionTime: .atDocumentStart,
                                      forMainFrameOnly: false))
        uc.addUserScript(WKUserScript(source: Rules.storageJS,
                                      injectionTime: .atDocumentStart,
                                      forMainFrameOnly: false))   // ③ 清 localStorage 计量
        uc.addUserScript(WKUserScript(source: Rules.cleanupJS,
                                      injectionTime: .atDocumentEnd,
                                      forMainFrameOnly: false))   // ④ 清 DOM / 去模糊
        return cfg
    }

    // MARK: - WebView 池（省掉每篇 ~100ms 的创建/冷启动）

    private var pool: [String: [WKWebView]] = [:]
    private let poolLock = NSLock()

    /// 取一个可用的 WebView（优先复用），调用方用完必须 recycle
    func makeWebView(site: Site, userAgent: String) -> WKWebView {
        poolLock.lock()
        if var arr = pool[site.rawValue], !arr.isEmpty {
            let wv = arr.removeLast()
            pool[site.rawValue] = arr
            poolLock.unlock()
            wv.customUserAgent = userAgent
            return wv
        }
        poolLock.unlock()
        return buildWebView(site: site, userAgent: userAgent)
    }

    private func buildWebView(site: Site, userAgent: String) -> WKWebView {
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                           configuration: makeConfiguration(site: site))
        wv.customUserAgent = userAgent
        wv.isOpaque = true
        wv.backgroundColor = .black
        return wv
    }

    /// 归还 WebView（上限 3/站点），清空内容避免残留上一页的 JS 状态
    func recycle(_ wv: WKWebView, site: Site) {
        wv.stopLoading()
        wv.navigationDelegate = nil
        wv.scrollView.delegate = nil
        wv.loadHTMLString("<html><body></body></html>", baseURL: nil)
        poolLock.lock()
        var arr = pool[site.rawValue] ?? []
        if arr.count < 3 { arr.append(wv) }
        pool[site.rawValue] = arr
        poolLock.unlock()
    }

    /// 预热：建好 WebView 并**真正访问站点首页**——先拿到 cf_clearance / 同意 cookie，
    /// 之后抓文章就不用重新过一遍人机验证（既提速也降检测概率）。
    func warmUp(site: Site) {
        guard let host = site.domains.first,
              let home = URL(string: "https://www.\(host)/") else { return }
        DispatchQueue.main.async {
            let wv = self.makeWebView(site: site, userAgent: Rules.chromeUA)
            wv.load(self.request(for: home, site: site))
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                self.recycle(wv, site: site)
            }
        }
    }

    /// 请求头：Referer + 语言（对应 BPC 的 modifyHeaders）
    func request(for url: URL, site: Site) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30)
        for (k, v) in Stealth.headers(for: site, url: url) {
            r.setValue(v, forHTTPHeaderField: k)
        }
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

    /// 站点首页/栏目页（发现层的网页兜底也要用同一套规则与指纹）
    func homeRequest(for url: URL) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        r.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        r.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                   forHTTPHeaderField: "Accept")
        return r
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

        // 只接受彭博/路透自己的文章地址
        let host = url.host ?? ""
        if !site.domains.contains(where: { host.contains($0) }) {
            onFail(FetchError.loadFailed("非目标站点地址：\(host)"))
            return
        }

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
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)

            wv.load(PaywallEngine.shared.request(for: url, site: site))
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastFinalURL = webView.url?.absoluteString ?? articleURL.absoluteString
        // 打开的是同意/条款页（不是文章）→ 直接判失败，避免把条款当正文
        let pageTitle = webView.title ?? ""
        if pageTitle.contains("Before you continue") || pageTitle.contains("在你继续")
            || lastFinalURL.contains("consent.") {
            finish(.failure(FetchError.loadFailed("打开的是同意页，不是文章")))
            return
        }
        // 先探测是否停在人机验证/拦截页；挑战页要等它自己放行（Cloudflare 无感验证通常 3–8 秒）
        waitChallengeThenExtract(attempt: 0)
    }

    /// 正文就绪即提取：每 200ms 探一次，最多 4 秒（快于固定等待）
    private func waitReadyThenExtract(attempt: Int) {
        guard let wv = webView else { return }
        wv.evaluateJavaScript(Rules.readyProbe) { [weak self] res, _ in
            guard let self = self else { return }
            if (res as? Bool) == true || attempt >= 20 {
                self.extract()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.waitReadyThenExtract(attempt: attempt + 1)
            }
        }
    }

    private func waitChallengeThenExtract(attempt: Int) {
        guard let wv = webView else { return }
        wv.evaluateJavaScript(Rules.challengeProbe) { [weak self] res, _ in
            guard let self = self else { return }
            let state = (res as? String) ?? "ok"
            if state == "ok" {
                // 放行后：等到正文节点出现就立刻取，不再固定睡 1.2 秒
                self.waitReadyThenExtract(attempt: 0)
                return
            }
            if attempt >= 12 {
                // 挑战没放过：先试 archive 镜像，仍不行才报错（并指引用网页模式）
                if !self.archiveTried {
                    self.archiveFallback()
                    return
                }
                let msg = state == "challenge"
                    ? "被站点人机验证拦截，请点右上角地球图标用网页模式手动通过"
                    : "被站点拒绝访问（可能触发风控），请稍后重试或改用网页模式"
                self.finish(.failure(FetchError.loadFailed(msg)))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.waitChallengeThenExtract(attempt: attempt + 1)
            }
        }
    }

    /// 轮询等待 Google 页的 JS 跳转；同时尝试从页面里直接挖发布方链接
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
                // 纯文本模式：图片块直接丢弃（用户要的是速度，不是图）
                if b.type == "img" { return nil }
                // 去掉内联标签（<a>、<em> 等），只保留纯文字：用户要求正文不显示链接
                let plain = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                let clean = plain.replacingOccurrences(of: "&nbsp;", with: " ").trimmed
                return clean.isEmpty && b.type != "hr" ? nil : Block(type: b.type, text: clean, src: nil)
            }

            // 用「过滤前」的原始段数判定是否抓到了正文（纯文本模式下图片被丢弃，不能用过滤后的数量）
            let rawCount = (raw?.blocks ?? []).filter { $0.type != "img" }.count
            if rawCount < 3 && !self.archiveTried {
                self.archiveFallback()
                return
            }
            // 拦截页文案 / 站点页脚样板混入正文 → 视为抓取失败，先试 archive
            let joined = blocks.map { $0.text }.joined(separator: " ")
            if Rules.looksUnusable(joined) {
                if !self.archiveTried { self.archiveFallback(); return }
                self.finish(.failure(FetchError.loadFailed("抓到的是验证页或站点页脚，请用网页模式")))
                return
            }
            if rawCount < 3 {
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
        if let wv = webView {
            PaywallEngine.shared.recycle(wv, site: site)   // 复用，减少下次创建开销
        }
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
