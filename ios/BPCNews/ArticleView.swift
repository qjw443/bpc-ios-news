import SwiftUI
import AVFoundation

struct ArticleView: View {
    let id: String

    @State private var article: Article?
    @State private var showOriginal = false
    @State private var errorText = ""
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            ScrollView {
                if let a = article {
                    VStack(alignment: .leading, spacing: 0) {
                        header(a)
                        Hairline().padding(.top, 18)
                        body(a)
                        footer(a)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                } else if !errorText.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 22))
                        Text(errorText)
                            .font(.system(size: 13))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundColor(Color(red: 1, green: 0.36, blue: 0.32))
                    .padding(.horizontal, 40)
                    .padding(.top, 120)
                } else {
                    ProgressView().tint(Theme.ink).padding(.top, 140)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .safeAreaInset(edge: .bottom) { if article != nil { bottomBar } }
        .task { await load() }
    }

    // MARK: - 头部

    @ViewBuilder
    private func header(_ a: Article) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                SourceTag(site: a.site)
                Kicker(text: kickerText(a), size: 9)
                Spacer()
            }
            .padding(.top, 10)

            Text(a.titleZh)
                .font(.editorial(28))
                .foregroundColor(Theme.ink)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            if !a.brief.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Kicker(text: "要点", color: Theme.orange, size: 9)
                    ForEach(a.brief, id: \.self) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Rectangle()
                                .fill(Theme.orange)
                                .frame(width: 2)
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

    private func kickerText(_ a: Article) -> String {
        var bits: [String] = []
        if let ts = a.publishedTs { bits.append(FeedRow.relative(ts)) }
        bits.append("约 \(readingMinutes(a)) 分钟")
        bits.append("\(a.blocks.count) 段")
        return bits.joined(separator: "　·　")
    }

    private func readingMinutes(_ a: Article) -> Int {
        let chars = a.blocks.reduce(0) { $0 + ($1.zh?.isEmpty == false ? $1.zh! : $1.text).count }
        return max(1, min(30, chars / 400))
    }

    // MARK: - 正文

    @ViewBuilder
    private func body(_ a: Article) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(a.blocks.indices, id: \.self) { i in
                blockRow(a.blocks[i], showOriginal: showOriginal)
            }
        }
        .padding(.top, 18)
    }

    @ViewBuilder
    private func blockRow(_ b: Block, showOriginal: Bool) -> some View {
        let zh = b.zh ?? ""
        let text = showOriginal ? b.text : (zh.isEmpty ? b.text : zh)

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
                Rectangle()
                    .fill(Theme.orange)
                    .frame(width: 2)
                Text(text)
                    .font(.editorial(17, weight: .regular))
                    .foregroundColor(Color(red: 0.86, green: 0.86, blue: 0.85))
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)

        case "li":
            HStack(alignment: .top, spacing: 9) {
                Text("—")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.orange)
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
                        case .success(let image):
                            image.resizable().scaledToFit()
                        default:
                            Rectangle().fill(Theme.raised).frame(height: 160)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    if !b.text.isEmpty {
                        Kicker(text: b.text, size: 9)
                    }
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

    // MARK: - 底部

    @ViewBuilder
    private func footer(_ a: Article) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Hairline().padding(.top, 22)
            Kicker(text: a.site == "bloomberg" ? "Source · Bloomberg" : "Source · Reuters", size: 9)
                .padding(.top, 12)
            if let url = URL(string: a.url) {
                Link(destination: url) {
                    HStack(spacing: 5) {
                        Text("查看原文")
                            .font(.system(size: 13, weight: .semibold))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundColor(Theme.orange)
                }
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 10) {
                if let a = article, let audio = a.audio, !audio.isEmpty,
                   let u = URL(string: audio) {
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

                HStack(spacing: 0) {
                    segment("译文", active: !showOriginal) { showOriginal = false }
                    segment("原文", active: showOriginal) { showOriginal = true }
                }
                .padding(3)
                .background(Theme.raised)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
        }
        .background(Theme.bg.opacity(0.96))
    }

    private func segment(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(active ? Theme.bg : Theme.inkDim)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(active ? Theme.ink : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 加载

    private func load() async {
        if let cached = Cache.loadArticle(id) {
            article = cached
        }
        do {
            let fresh: Article = try await APIClient.get("/v1/article/\(id)", as: Article.self)
            article = fresh
            Cache.saveArticle(fresh)
            errorText = ""
        } catch {
            if article == nil {
                errorText = "取稿失败：" + error.localizedDescription
            }
        }
    }
}
