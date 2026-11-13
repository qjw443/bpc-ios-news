import Foundation
import WebKit

/// 浏览器中继：用 WKWebView 去取「HTTP 客户端过不去」的资源。
///
/// 为什么需要它：
///   路透的 sitemap/API 对本机（乃至区域站、公开中转）一律返回 401——那是**边缘 JS 挑战**，
///   挑战页靠执行 JS 换取通行 cookie。任何 URLSession 客户端都拿不到内容，
///   但 WKWebView 是完整浏览器，能执行 JS、能保存 cookie —— 于是由它去取，
///   取到后把正文文本交回给我们的 XML 解析器。
///
/// 判定逻辑：
///   · 内容里出现 "Please enable JS" / "Access Denied" / 长度过短 → 视为仍在挑战，重载重试
///   · 否则视为拿到真实内容（XML / JSON / HTML）
final class BrowserFetcher: NSObject, WKNavigationDelegate {

    private var webView: WKWebView?
    private var done: ((String) -> Void)?
    private var site: Site = .reuters
    private var target = ""
    private var attempt = 0
    private var maxAttempts = 3
    private var finished = false
    private var deadline: DispatchWorkItem?

    private static let challengeMarkers = [
        "please enable js", "access denied", "are you a robot",
        "enable javascript", "cf-browser-verification", "just a moment",
    ]

    func fetchText(urlString: String, site: Site, attempts: Int = 3,
                   done: @escaping (String) -> Void) {
        self.site = site
        self.target = urlString
        self.maxAttempts = max(1, attempts)
        self.done = done
        load()
    }

    private func load() {
        guard !finished else { return }
        attempt += 1
        PaywallEngine.shared.prepare { [weak self] in
            guard let self = self, let url = URL(string: self.target) else {
                self?.finish("")
                return
            }
            let wv = PaywallEngine.shared.makeWebView(site: self.site, userAgent: Rules.chromeUA)
            wv.navigationDelegate = self
            self.webView = wv
            wv.load(PaywallEngine.shared.request(for: url, site: self.site))

            // 单次尝试上限 12s
            let work = DispatchWorkItem { [weak self] in
                self?.finish("")
            }
            self.deadline = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        deadline?.cancel()
        // XML/JSON 在 WKWebView 里会渲染成文本节点
        webView.evaluateJavaScript(
            "document.body ? document.body.innerText : (document.documentElement ? document.documentElement.innerText : '')"
        ) { [weak self] result, _ in
            guard let self = self else { return }
            let text = (result as? String) ?? ""
            let low = text.lowercased()
            let challenged = Self.challengeMarkers.contains { low.contains($0) }
            let looksReal = text.count > 400
                && (low.contains("<urlset") || low.contains("<sitemapindex")
                    || low.contains("\"headlines\"") || low.contains("<item"))

            if looksReal && !challenged {
                self.finish(text)
                return
            }
            if self.attempt < self.maxAttempts {
                // JS 挑战通常 2–6s 内放行：关掉旧视图，等一会儿重新开一个（携带刚下发的 cookie 不共享，
                // 所以这里靠重试而非复用；真实放行多发生在第 2 次）
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.load()
                }
            } else {
                self.finish(challenged ? "" : text)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleFailure()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        handleFailure()
    }

    /// 注意：不能在这里写 `webView(webView, didFail:…)`——形参名会遮蔽方法名
    private func handleFailure() {
        deadline?.cancel()
        if attempt < maxAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.load()
            }
        } else {
            finish("")
        }
    }

    private func finish(_ text: String) {
        guard !finished else { return }
        finished = true
        deadline?.cancel()
        deadline = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        let cb = done
        done = nil
        cb?(text)
    }
}
