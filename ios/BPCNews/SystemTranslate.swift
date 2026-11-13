import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// Apple 端上翻译（iOS 18+）：系统内置模型，纯离线、不需要 Key、不经过任何服务器。
/// 首次使用会由系统弹出「下载语言包」，之后完全本地运行。
///
/// iOS 17.x 及以下没有这个框架，自动回落到内置词典（Dict）。
@available(iOS 18.0, *)
private struct SystemTranslateModifier: ViewModifier {
    let texts: [String]
    @Binding var results: [String]
    @Binding var busy: Bool
    @Binding var errorText: String
    let nonce: Int

    @State private var config: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: nonce) { _, _ in
                config = TranslationSession.Configuration(
                    source: Locale.Language(identifier: "en"),
                    target: Locale.Language(identifier: "zh-Hans"))
            }
            .translationTask(config) { session in
                await run(session)
            }
    }

    private func run(_ session: TranslationSession) async {
        guard !texts.isEmpty else {
            await MainActor.run { busy = false }
            return
        }
        do {
            // 需要时会弹系统语言包下载
            try await session.prepareTranslation()
            let requests: [TranslationSession.Request] = texts.enumerated().map { i, t in
                TranslationSession.Request(sourceText: t, clientIdentifier: String(i))
            }
            let responses = try await session.translations(from: requests)
            var out = [String](repeating: "", count: texts.count)
            for r in responses {
                if let cid = r.clientIdentifier, let i = Int(cid), i < out.count {
                    out[i] = r.targetText
                }
            }
            await MainActor.run {
                results = out
                busy = false
            }
        } catch {
            await MainActor.run {
                busy = false
                errorText = "系统翻译未就绪：" + error.localizedDescription
            }
        }
    }
}

/// 运行时决定用不用系统翻译（iOS 18+ 才挂载 modifier，低版本原样返回内容）
struct SystemTranslateBox<Content: View>: View {
    let texts: [String]
    @Binding var results: [String]
    @Binding var busy: Bool
    @Binding var errorText: String
    let nonce: Int
    private let content: () -> Content

    init(texts: [String],
         results: Binding<[String]>,
         busy: Binding<Bool>,
         errorText: Binding<String>,
         nonce: Int,
         @ViewBuilder content: @escaping () -> Content) {
        self.texts = texts
        self._results = results
        self._busy = busy
        self._errorText = errorText
        self.nonce = nonce
        self.content = content
    }

    var body: some View {
        if #available(iOS 18.0, *) {
            content()
                .modifier(SystemTranslateModifier(texts: texts, results: $results,
                                                  busy: $busy, errorText: $errorText,
                                                  nonce: nonce))
        } else {
            content()
        }
    }
}

enum SystemTranslate {
    static var isAvailable: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }
}
