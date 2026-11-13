import SwiftUI
import WebKit
import Vision

// MARK: - 通用「自动中文化」网页页

/// 一个可复用的内嵌网页页：进入即自动把英文翻成中文，持续增量补翻，可选图片 OCR 对照。
struct TranslatedWebPage: View {
    let title: String
    let subtitle: String
    let urlString: String
    var autoImages: Bool = false

    @StateObject private var ctl: WebPageController
    @State private var busyText = false
    @State private var busyImage = false
    @State private var status = "加载中…"
    @State private var imagesDone = false
    @State private var rounds = 0

    init(title: String, subtitle: String, urlString: String, autoImages: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.urlString = urlString
        self.autoImages = autoImages
        _ctl = StateObject(wrappedValue: WebPageController(urlString: urlString))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    Divider().overlay(Theme.hairline)
                    WebContainer(webView: ctl.webView)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(busyText || busyImage ? Theme.orange : Theme.hairline)
                            .frame(width: 4, height: 4)
                        Text(status)
                            .font(.system(size: 10))
                            .foregroundColor(Theme.inkDim)
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Theme.surface)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear { ctl.load() }
        .onChange(of: ctl.ready) { ok in
            guard ok else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { translateText() }
            guard autoImages else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                if !imagesDone { imagesDone = true; translateImages() }
            }
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            guard ctl.ready, !busyText, !busyImage, rounds < 60 else { return }
            translateText()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundColor(Theme.ink)
                Kicker(text: subtitle, size: 8)
            }
            Spacer()
            Button {
                rounds = 0
                imagesDone = false
                status = "重新加载…"
                ctl.webView.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.ink)
                    .frame(width: 32, height: 30)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.bg)
    }

    // MARK: 正文（增量）

    private func translateText() {
        guard !busyText else { return }
        busyText = true
        rounds += 1

        ctl.webView.evaluateJavaScript(PageJS.collectTexts) { result, _ in
            guard let s = result as? String,
                  let data = s.data(using: .utf8),
                  let texts = try? JSONSerialization.jsonObject(with: data) as? [String],
                  !texts.isEmpty else {
                busyText = false
                status = imagesDone ? "中文对照完成" : "已是中文"
                return
            }
            status = "翻译 \(texts.count) 段…"
            TranslateService.shared.translate(texts) { zh, source in
                let payload = (try? JSONSerialization.data(withJSONObject: zh)) ?? Data("[]".utf8)
                let js = "window.__bpcApplyTexts("
                    + (String(data: payload, encoding: .utf8) ?? "[]") + ");"
                ctl.webView.evaluateJavaScript(js) { res, _ in
                    busyText = false
                    let applied = (res as? NSNumber)?.intValue ?? zh.count
                    status = "已中文 \(applied) 段（\(source.rawValue)）"
                }
            }
        }
    }

    // MARK: 图片（可选）

    private func translateImages() {
        guard !busyImage else { return }
        busyImage = true
        status = "识别图中文字…"

        ctl.webView.evaluateJavaScript(PageJS.collectImages) { result, _ in
            guard let s = result as? String,
                  let data = s.data(using: .utf8),
                  let imgs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  !imgs.isEmpty else {
                busyImage = false
                status = "没有需要翻译的图片"
                return
            }
            self.runImagePipeline(imgs, index: 0, done: 0)
        }
    }

    private func runImagePipeline(_ imgs: [[String: Any]], index: Int, done: Int) {
        guard index < imgs.count else {
            busyImage = false
            status = "完成：正文中文 · \(done) 张图有对照"
            return
        }
        guard let src = imgs[index]["src"] as? String, let url = URL(string: src) else {
            runImagePipeline(imgs, index: index + 1, done: done)
            return
        }
        status = "识别第 \(index + 1)/\(imgs.count) 张…"

        var req = URLRequest(url: url, timeoutInterval: 15)
        if let host = URL(string: urlString)?.host {
            req.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        }
        req.setValue(Rules.chromeUA, forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data, data.count > 2000 else {
                DispatchQueue.main.async { self.runImagePipeline(imgs, index: index + 1, done: done) }
                return
            }
            OCR.lines(from: data) { lines in
                guard !lines.isEmpty else {
                    DispatchQueue.main.async { self.runImagePipeline(imgs, index: index + 1, done: done) }
                    return
                }
                TranslateService.shared.translate(lines.map { $0.text }) { zh, _ in
                    var items: [[String: Any]] = []
                    for (i, line) in lines.enumerated() where i < zh.count {
                        let t = zh[i]
                        guard !t.isEmpty, t != line.text else { continue }
                        items.append(["t": t])
                    }
                    DispatchQueue.main.async {
                        guard !items.isEmpty else {
                            self.runImagePipeline(imgs, index: index + 1, done: done)
                            return
                        }
                        let payload = (try? JSONSerialization.data(withJSONObject: items)) ?? Data("[]".utf8)
                        let js = "window.__bpcCaption(\(index), "
                            + (String(data: payload, encoding: .utf8) ?? "[]") + ");"
                        self.ctl.webView.evaluateJavaScript(js) { _, _ in
                            self.runImagePipeline(imgs, index: index + 1, done: done + 1)
                        }
                    }
                }
            }
        }.resume()
    }
}

// MARK: - 三个页签的具体实例

/// 宏观：Yardeni 图表（英文，自动中文 + 图片对照）
struct MacroView: View {
    var body: some View {
        TranslatedWebPage(title: "宏观图表",
                          subtitle: "YARDENI · CHARTS　自动中文",
                          urlString: "https://yardeni.com/charts/",
                          autoImages: true)
    }
}

/// 预测市场：Polymarket 中文站（本身中文，英文碎片会自动补齐）
struct PolyView: View {
    var body: some View {
        TranslatedWebPage(title: "预测市场",
                          subtitle: "POLYMARKET　自动中文",
                          urlString: "https://polymarket.com/zh/markets",
                          autoImages: false)
    }
}

// MARK: - WebView

struct WebContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

final class WebPageController: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published var ready = false
    private let urlString: String
    private var loadedOnce = false

    init(urlString: String) {
        self.urlString = urlString
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        webView.customUserAgent = Rules.chromeUA
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = UIColor.black
    }

    func load() {
        guard !loadedOnce, let url = URL(string: urlString) else { return }
        loadedOnce = true
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(Rules.chromeUA, forHTTPHeaderField: "User-Agent")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        webView.load(req)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        // SPA 会在 hydration 后重绘，稍后重置就绪标记以触发下一轮增量翻译
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.ready = true
        }
    }
}

// MARK: - OCR

enum OCR {
    struct Line { let text: String }

    static func lines(from imageData: Data, completion: @escaping ([Line]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let src = CGImageSourceCreateWithData(imageData as CFData, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let req = VNRecognizeTextRequest { request, _ in
                var out: [Line] = []
                for case let obs as VNRecognizedTextObservation in (request.results ?? []) {
                    guard let top = obs.topCandidates(1).first else { continue }
                    let t = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard t.count > 2, t.rangeOfCharacter(from: .letters) != nil else { continue }
                    out.append(Line(text: t))
                }
                DispatchQueue.main.async { completion(out) }
            }
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            req.recognitionLanguages = ["en-US"]
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            try? handler.perform([req])
        }
    }
}

// MARK: - 注入脚本

enum PageJS {

    /// 只收集「不含中文的英文文本节点」，因此可反复增量调用
    static let collectTexts = """
    (function(){
      window.__bpcNodes = [];
      var out = [];
      try {
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
        var n;
        while ((n = walker.nextNode())) {
          var t = (n.nodeValue || '').trim();
          if (t.length > 2 && /[A-Za-z]{3}/.test(t) && !/[\\u4e00-\\u9fff]/.test(t)) {
            window.__bpcNodes.push(n);
            out.push(t);
            if (out.length >= 200) break;
          }
        }
      } catch (e) {}
      window.__bpcApplyTexts = function(arr){
        var c = 0;
        for (var i = 0; i < arr.length && i < window.__bpcNodes.length; i++) {
          if (arr[i]) { window.__bpcNodes[i].nodeValue = arr[i]; c++; }
        }
        return c;
      };
      return JSON.stringify(out);
    })();
    """

    static let collectImages = """
    (function(){
      var out = [];
      var imgs = document.images;
      for (var i = 0; i < imgs.length && out.length < 8; i++) {
        var im = imgs[i];
        if (!im.src || im.src.indexOf('data:') === 0) continue;
        if (im.naturalWidth < 320 || im.naturalHeight < 160) continue;
        out.push({i: i, src: im.src, w: im.naturalWidth, h: im.naturalHeight});
      }
      window.__bpcCaption = function(idx, items){
        try {
          var im = document.images[idx];
          if (!im) return 0;
          if (im.getAttribute('data-bpc-done') === '1') return 0;
          im.setAttribute('data-bpc-done', '1');
          var host = im.closest('figure') || im.parentElement || im;
          var box = document.createElement('div');
          box.setAttribute('data-bpc-caption', '1');
          box.style.cssText = 'margin:10px 0 20px;padding:10px 12px;'
            + 'border-left:3px solid #ff6b00;background:rgba(255,255,255,.06);'
            + 'font-size:14px;line-height:1.55;color:#e9e9e9;font-family:-apple-system;';
          for (var k = 0; k < items.length; k++) {
            var p = document.createElement('div');
            p.textContent = items[k].t;
            if (k) p.style.marginTop = '4px';
            box.appendChild(p);
          }
          host.parentNode.insertBefore(box, host.nextSibling);
          return items.length;
        } catch (e) { return -1; }
      };
      return JSON.stringify(out);
    })();
    """
}
