import SwiftUI
import AVFoundation

struct ReaderView: View {
    let itemId: String

    @ObservedObject private var store = FeedStore.shared
    @State private var article: Article?
    @State private var showOriginal = false
    @State private var showWeb = false
    @State private var loading = false
    @State private var errorText = ""
    @State private var translating = false
    @State private var player: AVPlayer?

    private var item: FeedItem? { Library.shared.item(for: itemId) }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                if let a = article, a.blocks.count >= 3 {
                    VStack(alignment: .leading, spacing: 0) {
                        header(a)
                        Hairline().padding(.top, 18)
                        contentList(a)
                        footer(a)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                } else if loading {
                    loadingView
                } else {
                    failView
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    Button {
                        showWeb = true
                    } label: {
                        Image(systemName: "safari")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Theme.ink)
                    }
                    Button(showOriginal ? "译文" : "原文") { showOriginal.toggle() }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.orange)
                        .disabled(article == nil)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if article != nil { bottomBar }
        }
        .sheet(isPresented: $showWeb) {
            if let it = item, let url = URL(string: it.url) {
                WebReaderScreen(url: url, site: it.site)
            }
        }
        .task { load() }
    }

    // MARK: 头

    private func header(_ a: Article) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SourceTag(site: a.site.rawValue)
                Kicker(text: "\(a.blocks.count) 段 · \(a.fromArchive ? "archive 镜像" : "App 内直取")", size: 9)
                Spacer()
                if !a.titleZh.isEmpty { Kicker(text: "已译", color: Theme.orange, size: 9) }
            }
            .padding(.top, 10)

            Text(a.titleZh.isEmpty ? a.title : a.titleZh)
                .font(.editorial(27))
                .foregroundColor(Theme.ink)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            if !a.titleZh.isEmpty {
                Text(a.title)
                    .font(.editorial(15, weight: .regular))
                    .foregroundColor(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !a.brief.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Kicker(text: "要点", color: Theme.orange, size: 9)
                    ForEach(a.brief, id: \.self) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Rectangle().fill(Theme.orange).frame(width: 2)
                            Text(line)
                                .font(.system(size: 13))
                                .foregroundColor(Theme.inkDim)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: 正文

    private func contentList(_ a: Article) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(a.blocks.indices, id: \.self) { i in
                blockRow(a.blocks[i], showOriginal: showOriginal)
            }
        }
        .padding(.top, 18)
    }

    @ViewBuilder
    private func blockRow(_ b: Block, showOriginal: Bool) -> some View {
        let zh = b.zh
        let text = showOriginal ? b.text : ((zh?.isEmpty == false) ? zh! : b.text)

        switch b.type {
        case "h2":
            Text(text)
                .font(.editorial(20, weight: .semibold))
                .foregroundColor(Theme.ink)
                .lineSpacing(4)
                .padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)
        case "quote":
            HStack(alignment: .top, spacing: 12) {
                Rectangle().fill(Theme.orange).frame(width: 2)
                Text(text)
                    .font(.editorial(17, weight: .regular))
                    .foregroundColor(Color(red: 0.86, green: 0.86, blue: 0.85))
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case "li":
            HStack(alignment: .top, spacing: 9) {
                Text("—").font(.system(size: 13)).foregroundColor(Theme.orange)
                Text(text)
                    .font(.system(size: 15))
                    .foregroundColor(Theme.ink)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case "hr":
            Hairline().padding(.vertical, 6)
        case "img":
            if let src = b.src, let url = URL(string: src) {
                VStack(alignment: .leading, spacing: 6) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFit()
                        default: Rectangle().fill(Theme.raised).frame(height: 160)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    if !b.text.isEmpty { Kicker(text: b.text, size: 9) }
                }
            }
        default:
            Text(text)
                .font(.system(size: 16))
                .foregroundColor(Color(red: 0.90, green: 0.90, blue: 0.89))
                .lineSpacing(7)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func footer(_ a: Article) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Hairline().padding(.top, 22)
            Kicker(text: a.site == .bloomberg ? "Source · Bloomberg" : "Source · Reuters", size: 9)
                .padding(.top, 12)
            if let url = URL(string: a.url), !a.url.contains("news.google.com") {
                Link(destination: url) {
                    HStack(spacing: 5) {
                        Text("查看原文").font(.system(size: 13, weight: .semibold))
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold))
                    }
                    .foregroundColor(Theme.orange)
                }
            }
            Text("正文由 App 内置引擎在本机解析；请在设置中确认来源与翻译选项。")
                .font(.system(size: 10))
                .foregroundColor(Theme.inkDim)
                .padding(.top, 2)
        }
    }

    // MARK: 底栏

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 10) {
                if let a = article, let audio = a.audio, !audio.isEmpty, let u = URL(string: audio) {
                    Button {
                        player = AVPlayer(url: u)
                        player?.play()
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(Theme.ink)
                            .frame(width: 38, height: 32)
                            .background(Theme.raised)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if !Settings.llmKey.isEmpty {
                    Button {
                        translate()
                    } label: {
                        HStack(spacing: 6) {
                            if translating { ProgressView().tint(Theme.ink) }
                            Text(translating ? "翻译中" : "译成中文")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Theme.ink)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Theme.raised)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(translating)
                }
                HStack(spacing: 0) {
                    segment("译文", active: !showOriginal) { showOriginal = false }
                    segment("原文", active: showOriginal) { showOriginal = true }
                }
                .padding(3)
                .background(Theme.raised)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .padding(.horizontal, 18).padding(.vertical, 9)
        }
        .background(Theme.bg.opacity(0.96))
    }

    private func segment(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(active ? Theme.bg : Theme.inkDim)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(active ? Theme.ink : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: 状态

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView().tint(Theme.ink)
            Kicker(text: "正在本机抓取并解除付费墙", size: 9)
            Text("已拦截付费墙脚本 · 正在提取正文")
                .font(.system(size: 12))
                .foregroundColor(Theme.inkDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 140)
    }

    private var failView: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 22))
            Text(errorText.isEmpty ? "还没有正文" : errorText)
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("重试") { load() }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.bg)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Theme.ink)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Button("用网页模式看") { showWeb = true }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.orange)
            }
        }
        .foregroundColor(Theme.inkDim)
        .padding(.horizontal, 32)
        .padding(.top, 120)
    }

    // MARK: 动作

    private func load() {
        if let cached = Library.shared.article(for: itemId), cached.blocks.count >= 3 {
            article = cached
            if Settings.translateOnOpen { translate() }
            return
        }
        guard let it = item else {
            errorText = "条目已不存在"
            return
        }
        loading = true
        errorText = ""
        store.fetch(item: it) { art in
            loading = false
            if let art = art {
                article = art
                if Settings.translateOnOpen { translate() }
            } else {
                errorText = store.lastError.isEmpty ? "正文抓取失败，可试网页模式" : store.lastError
            }
        }
    }

    private func translate() {
        guard let a = article, !translating else { return }
        translating = true
        Translator.translate(a) { result in
            switch result {
            case .success(let updated):
                Translator.translateTitle(updated.title) { zh in
                    DispatchQueue.main.async {
                        translating = false
                        var u = updated
                        if !zh.isEmpty { u.titleZh = zh }
                        article = u
                        Library.shared.markFetched(itemId, article: u)
                    }
                }
            case .failure(let e):
                DispatchQueue.main.async {
                    translating = false
                    errorText = e.localizedDescription
                }
            }
        }
    }
}
