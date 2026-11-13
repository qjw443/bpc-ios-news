import SwiftUI
import WebKit

/// 直接把站点原始页面装进带「付费墙拦截规则」的 WKWebView。
/// 用于兜底：原生提取失败时，用户仍能在 App 内读全文。
struct PaywallWebView: UIViewRepresentable {
    let url: URL
    let site: Site
    @Binding var loading: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let wv = PaywallEngine.shared.makeWebView(site: site, userAgent: Rules.chromeUA)
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.load(PaywallEngine.shared.request(for: url, site: site))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: PaywallWebView
        init(_ parent: PaywallWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.loading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            parent.loading = false
        }
    }
}

struct WebReaderScreen: View {
    let url: URL
    let site: Site

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                PaywallWebView(url: url, site: site, loading: $loading)
                if loading {
                    VStack(spacing: 10) {
                        ProgressView().tint(Theme.ink)
                        Kicker(text: "载入原始页面 · 付费墙已拦截", size: 9)
                    }
                    .padding(18)
                    .background(Theme.bg.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .navigationTitle(site.label + " · 原始页面")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }.foregroundColor(Theme.ink)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        openURL(url)
                    } label: {
                        Image(systemName: "safari").foregroundColor(Theme.ink)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
