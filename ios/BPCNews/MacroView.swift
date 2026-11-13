import SwiftUI
import WebKit
import Vision

/// 宏观页：内嵌 yardeni.com/charts（图表站）
///   · 页面正文中文化
///   · 图片内文字翻译：Vision OCR → 翻译 → 以「图下对照块」呈现（不覆盖原图，避免影响看图）
struct MacroView: View {
    @StateObject private var ctl = MacroController()
    @State private var busyText = false
    @State private var busyImage = false
    @State private var status = ""
    @AppStorage("macro_translated") private var translatedOnce = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    Divider().overlay(Theme.hairline)
                    WebContainer(webView: ctl.webView)
                    if !status.isEmpty {
                        Text(status)
                            .font(.system(size: 10))
                            .foregroundColor(Theme.inkDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(Theme.surface)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            ctl.load()
            if !translatedOnce {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                    translateText()
                    translatedOnce = true
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("宏观图表")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundColor(Theme.ink)
                Kicker(text: "YARDENI · CHARTS", size: 8)
            }
            Spacer()
            actionButton(title: busyText ? "译中…" : "中文",
                         icon: "character.book.closed", busy: busyText) { translateText() }
            actionButton(title: busyImage ? "译图中…" : "图片翻译",
                         icon: "photo.on.rectangle.angled", busy: busyImage) { translateImages() }
            Button {
                ctl.webView.reload()
                status = ""
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

    private func actionButton(title: String, icon: String, busy: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundColor(busy ? Theme.inkDim : Theme.orange)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .disabled(busy)
    }

    // MARK: - 正文翻译

    private func translateText() {
        guard !busyText else { return }
        busyText = true
        status = "正在读取页面文字…"

        ctl.webView.evaluateJavaScript(MacroJS.collectTexts) { result, _ in
            guard let s = result as? String,
                  let data = s.data(using: .utf8),
                  let texts = try? JSONSerialization.jsonObject(with: data) as? [String],
                  !texts.isEmpty else {
                busyText = false
                status = "页面没有可翻译的英文段落（或尚未加载完）"
                return
            }
            status = "翻译 \(texts.count) 段…"
            TranslateService.shared.translate(texts) { zh, source in
                let payload = (try? JSONSerialization.data(withJSONObject: zh)) ?? Data("[]".utf8)
                let js = "window.__bpcApplyTexts("
                    + (String(data: payload, encoding: .utf8) ?? "[]") + ");"
                ctl.webView.evaluateJavaScript(js) { _, _ in
                    busyText = false
                    status = "已翻译 \(zh.count) 段（\(source.rawValue)）"
                }
            }
        }
    }

    // MARK: - 图片翻译（OCR → 图下对照块）

    private func translateImages() {
        guard !busyImage else { return }
        busyImage = true
        status = "正在收集图片…"

        ctl.webView.evaluateJavaScript(MacroJS.collectImages) { result, _ in
            guard let s = result as? String,
                  let data = s.data(using: .utf8),
                  let imgs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  !imgs.isEmpty else {
                busyImage = false
                status = "没有找到可翻译的图片"
                return
            }
            status = "识别 \(imgs.count) 张图片…"
            self.runImagePipeline(imgs, index: 0, done: 0)
        }
    }

    private func runImagePipeline(_ imgs: [[String: Any]], index: Int, done: Int) {
        guard index < imgs.count else {
            busyImage = false
            status = "图片翻译完成：\(done) 张（译文在图下方对照）"
            return
        }
        guard let src = imgs[index]["src"] as? String, let url = URL(string: src) else {
            runImagePipeline(imgs, index: index + 1, done: done)
            return
        }
        status = "识别第 \(index + 1)/\(imgs.count) 张…"

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("https://yardeni.com/", forHTTPHeaderField: "Referer")
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
                        let js = "window.__bpcCaption("
                            + "\(index), "
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

// MARK: - WebView 容器

struct WebContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

final class MacroController: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    private var loaded = false

    override init() {
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
        guard !loaded, let url = URL(string: "https://yardeni.com/charts/") else { return }
        loaded = true
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(Rules.chromeUA, forHTTPHeaderField: "User-Agent")
        webView.load(req)
    }
}

// MARK: - OCR

enum OCR {
    struct Line {
        let text: String
    }

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

enum MacroJS {

    static let collectTexts = """
    (function(){
      window.__bpcNodes = [];
      var out = [];
      try {
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
        var n;
        while ((n = walker.nextNode())) {
          var t = (n.nodeValue || '').trim();
          if (t.length > 2 && /[A-Za-z]{3}/.test(t)) {
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
