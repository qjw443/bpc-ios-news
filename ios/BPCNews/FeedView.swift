import SwiftUI

struct FeedView: View {
    @EnvironmentObject private var store: FeedStore
    @State private var path: [String] = []
    @State private var showSettings = false

    // 列表标题的中文化（系统端上翻译）
    @State private var titleIds: [String] = []
    @State private var titleTexts: [String] = []
    @State private var titleResults: [String] = []
    @State private var titleBusy = false
    @State private var titleError = ""
    @State private var titleNonce = 0

    private let openItem = NotificationCenter.default.publisher(for: .bpcOpenItem)
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        SystemTranslateBox(texts: titleTexts,
                           results: $titleResults,
                           busy: $titleBusy,
                           errorText: $titleError,
                           nonce: titleNonce) {
            content
        }
        .onChange(of: titleResults) { new in
            applyTitles(new)
        }
    }

    private var content: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        masthead
                        if !store.lastError.isEmpty { errorStrip }
                        if store.items.isEmpty && !store.loading { emptyState }
                        ForEach(store.items) { item in
                            NavigationLink(value: item.id) {
                                FeedRow(item: item)
                            }
                            .buttonStyle(.plain)
                            Hairline().padding(.leading, 18)
                        }
                        colophon
                    }
                    .padding(.bottom, 28)
                }
                .refreshable { await pull() }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { ReaderView(itemId: $0) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    store.startMonitoring()
                    store.refresh { translateTitles() }
                }
            }
            .onChange(of: store.items.count) { _ in
                // 自动监控刷进新稿时也立刻翻译标题
                translateTitles()
            }
            .onReceive(openItem) { note in
                if let id = note.object as? String {
                    path = [id]
                    DeepLink.shared.pendingItemId = nil
                }
            }
            .onAppear {
                if let id = DeepLink.shared.pendingItemId {
                    path = [id]
                    DeepLink.shared.pendingItemId = nil
                }
                store.startMonitoring()
                if store.items.isEmpty { store.refresh() }
                translateTitles()
            }
        }
        .tint(Theme.ink)
        .preferredColorScheme(.dark)
    }

    private func pull() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            store.refresh {
                translateTitles()      // 新稿进来立刻翻，秒级出中文
                cont.resume()
            }
        }
    }

    // MARK: - 标题中文化

    /// 只翻「还没有中文」的前 25 条，交给系统端上翻译
    private func translateTitles() {
        guard Settings.zhMode == "sys" else { return }
        let todo = Array(store.items.filter { $0.titleZh.isEmpty }.prefix(25))
        guard !todo.isEmpty else { return }
        titleIds = todo.map { $0.id }
        titleTexts = todo.map { $0.title }
        titleResults = []
        titleBusy = true
        titleNonce += 1
    }

    private func applyTitles(_ zh: [String]) {
        guard !titleIds.isEmpty, zh.count == titleIds.count else { return }
        for (i, id) in titleIds.enumerated() where i < zh.count {
            let t = zh[i]
            if !t.isEmpty { Library.shared.setTitleZh(id, t) }
        }
        store.items = Library.shared.items
        titleIds = []
        titleTexts = []
        titleResults = []
        titleBusy = false
    }

    // MARK: 报头

    private var masthead: some View {
        VStack(spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("BPC MARKETS")
                        .font(.system(size: 17, weight: .heavy))
                        .tracking(3.4)
                        .foregroundColor(Theme.ink)
                    Kicker(text: "Bloomberg · Reuters　本机直连", size: 9)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button { store.refresh() } label: {
                        Image(systemName: store.loading ? "arrow.triangle.2.circlepath" : "bolt.horizontal")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.ink)
                            .padding(8)
                            .background(Theme.raised)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Theme.ink)
                            .padding(8)
                            .background(Theme.raised)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 7) {
                Circle().fill(store.lastError.isEmpty ? Theme.orange : Color.red)
                    .frame(width: 5, height: 5)
                Kicker(text: store.status.isEmpty ? "待命" : store.status,
                       color: store.lastError.isEmpty ? Theme.orange : .red, size: 9)
                Spacer()
                Kicker(text: "\(store.items.count) 条", size: 9)
            }
            Hairline()
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private var errorStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
            Text(store.lastError).font(.system(size: 11)).lineLimit(2)
            Spacer()
        }
        .foregroundColor(Color(red: 1, green: 0.36, blue: 0.32))
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Color(red: 0.16, green: 0.03, blue: 0.02))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Kicker(text: "No feed yet", color: Theme.orange)
            Text("还没有入稿").font(.editorial(26)).foregroundColor(Theme.ink)
            Text("下拉刷新即可开始抓取。首次会编译付费墙拦截规则（约 1 秒）。")
                .font(.system(size: 13)).foregroundColor(Theme.inkDim).lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.vertical, 40)
    }

    private var colophon: some View {
        VStack(spacing: 6) {
            Hairline().padding(.top, 24)
            Kicker(text: "App 内置绕过 · 无服务器 · 自签版", size: 8).padding(.top, 10)
        }
        .padding(.horizontal, 18)
    }
}
struct FeedRow: View {
    let item: FeedItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SourceTag(site: item.site.rawValue)
                    Kicker(text: TimeFmt.feedText(item.ts) + " 北京", size: 9)
                    Spacer()
                    if item.fetched {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(Theme.hairline)
                    }
                }

                Text(item.titleZh.isEmpty ? item.title : item.titleZh)
                    .font(.editorial(18))
                    .foregroundColor(Theme.ink)
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if !item.titleZh.isEmpty {
                    Text(item.title)
                        .font(.system(size: 11.5))
                        .foregroundColor(Theme.inkDim)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !item.brief.isEmpty {
                    Text(item.brief.joined(separator: "　／　"))
                        .font(.system(size: 12))
                        .foregroundColor(Theme.inkDim)
                        .lineLimit(2)
                }
            }

            thumbnail
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let s = item.imageURL, let u = URL(string: s) {
            AsyncImage(url: u) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    Rectangle().fill(Theme.raised)
                }
            }
            .frame(width: 86, height: 66)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Theme.raised)
                .frame(width: 86, height: 66)
                .overlay(
                    Image(systemName: "newspaper")
                        .font(.system(size: 15))
                        .foregroundColor(Theme.hairline)
                )
        }
    }
}
