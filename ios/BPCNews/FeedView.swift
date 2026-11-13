import SwiftUI
import UIKit

enum FeedFilter: String, CaseIterable, Identifiable {
    case all, unread, bloomberg, reuters, saved
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .unread: return "未读"
        case .bloomberg: return "彭博"
        case .reuters: return "路透"
        case .saved: return "收藏"
        }
    }
}

struct FeedView: View {
    @EnvironmentObject private var store: FeedStore
    @State private var path: [String] = []
    @State private var showSettings = false
    @State private var showOnboarding = false
    @AppStorage("onboarded") private var onboarded = false

    // 快捷筛选
    @State private var query = ""
    @State private var filter: FeedFilter = .all
    @State private var showSearch = false
    @State private var shareItems: [Any] = []
    @State private var showShare = false

    // 列表标题中文化
    @State private var titleIds: [String] = []
    @State private var titleTexts: [String] = []
    @State private var titleResults: [String] = []
    @State private var titleBusy = false
    @State private var titleError = ""
    @State private var titleNonce = 0
    @State private var activeNonce = -1

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
                    LazyVStack(spacing: 0, pinnedViews: []) {
                        masthead
                        quickBar
                        if !store.lastError.isEmpty { errorStrip }
                        if store.loading && store.items.isEmpty {
                            skeleton
                        } else if filtered.isEmpty {
                            emptyState
                        } else {
                            ForEach(filtered) { item in
                                NavigationLink(value: item.id) {
                                    FeedRow(item: item)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        Library.shared.toggleSaved(item.id)
                                        store.items = Library.shared.items
                                        haptic(.light)
                                    } label: {
                                        Label(item.saved ? "取消收藏" : "收藏",
                                              systemImage: item.saved ? "bookmark.slash" : "bookmark")
                                    }
                                    Button {
                                        Library.shared.markRead(item.id)
                                        store.items = Library.shared.items
                                        haptic(.light)
                                    } label: {
                                        Label(item.read ? "标记未读" : "标记已读",
                                              systemImage: item.read ? "circle" : "checkmark.circle")
                                    }
                                    Button {
                                        share(item)
                                    } label: {
                                        Label("分享", systemImage: "square.and.arrow.up")
                                    }
                                }
                                Hairline().padding(.leading, 18)
                            }
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
            .sheet(isPresented: $showOnboarding) { OnboardingView() }
            .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    store.startMonitoring()
                    store.refresh { translateTitles() }
                }
            }
            .onChange(of: store.items.count) { _ in translateTitles() }
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
                if !onboarded { showOnboarding = true }
                store.startMonitoring()
                if store.items.isEmpty { store.refresh() }
                translateTitles()
            }
        }
        .tint(Theme.ink)
        .preferredColorScheme(.dark)
    }

    // MARK: - 顶部：速度条

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("彭博与路透新闻")
                        .font(.system(size: 20, weight: .heavy))
                        .tracking(1.2)
                        .foregroundColor(Theme.ink)
                    Kicker(text: "BLOOMBERG · REUTERS　本机直连", size: 8.5)
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Button {
                        showSearch.toggle()
                    } label: {
                        Image(systemName: showSearch ? "xmark" : "magnifyingglass")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(showSearch ? Theme.orange : Theme.ink)
                            .frame(width: 30, height: 30)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    Button {
                        haptic(.medium)
                        store.refresh(notify: false) { translateTitles() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.ink)
                            .frame(width: 30, height: 30)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .rotationEffect(.degrees(store.loading ? 360 : 0))
                            .animation(store.loading
                                        ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                                        : .default, value: store.loading)
                    }
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.ink)
                            .frame(width: 30, height: 30)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
            }

            // 速度条：延迟 + 本轮耗时 + 条数
            HStack(spacing: 6) {
                Circle()
                    .fill(store.lastError.isEmpty ? Theme.orange : Color.red)
                    .frame(width: 5, height: 5)
                Kicker(text: store.latencyText, size: 8.5)
                Spacer()
                Kicker(text: "\(store.items.count) 条 · 未读 \(Library.shared.unreadCount)", size: 8.5)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    // MARK: - 快捷栏：搜索 + 筛选

    private var quickBar: some View {
        VStack(spacing: 8) {
            if showSearch {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11)).foregroundColor(Theme.inkDim)
                    TextField("搜索标题、摘要、作者", text: $query)
                        .font(.system(size: 12.5))
                        .foregroundColor(Theme.ink)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11)).foregroundColor(Theme.inkDim)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .padding(.horizontal, 18)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(FeedFilter.allCases) { f in
                        let n = count(f)
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { filter = f }
                            haptic(.light)
                        } label: {
                            HStack(spacing: 4) {
                                Text(f.title)
                                    .font(.system(size: 11, weight: filter == f ? .semibold : .regular))
                                if n > 0 {
                                    Text("\(n)")
                                        .font(.mono(9))
                                        .foregroundColor(filter == f ? Theme.bg.opacity(0.7) : Theme.inkDim)
                                }
                            }
                            .foregroundColor(filter == f ? Theme.bg : Theme.inkDim)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(filter == f ? Theme.ink : Theme.surface)
                            .clipShape(Capsule())
                        }
                    }
                }
                .padding(.horizontal, 18)
            }
        }
        .padding(.bottom, 10)
    }

    private func count(_ f: FeedFilter) -> Int {
        switch f {
        case .all: return store.items.count
        case .unread: return store.items.filter { !$0.read }.count
        case .bloomberg: return store.items.filter { $0.site == .bloomberg }.count
        case .reuters: return store.items.filter { $0.site == .reuters }.count
        case .saved: return store.items.filter { $0.saved }.count
        }
    }

    private var filtered: [FeedItem] {
        var base = store.items
        switch filter {
        case .all: break
        case .unread: base = base.filter { !$0.read }
        case .bloomberg: base = base.filter { $0.site == .bloomberg }
        case .reuters: base = base.filter { $0.site == .reuters }
        case .saved: base = base.filter { $0.saved }
        }
        let q = query.trimmedLower
        guard !q.isEmpty else { return base }
        return base.filter { it in
            it.title.lowercased().contains(q)
                || it.titleZh.contains(q)
                || it.summary.lowercased().contains(q)
                || it.author.lowercased().contains(q)
        }
    }

    // MARK: - 骨架 / 空态

    private var skeleton: some View {
        VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.raised).frame(width: 62, height: 12)
                        RoundedRectangle(cornerRadius: 2).fill(Theme.raised).frame(width: 40, height: 9)
                        Spacer()
                    }
                    RoundedRectangle(cornerRadius: 3).fill(Theme.raised).frame(height: 17)
                    RoundedRectangle(cornerRadius: 3).fill(Theme.raised).frame(width: 240, height: 17)
                    RoundedRectangle(cornerRadius: 3).fill(Theme.raised.opacity(0.6)).frame(height: 10)
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
                .opacity(0.55)
                Hairline().padding(.leading, 18)
            }
        }
        .redacted(reason: .placeholder)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: query.isEmpty && filter == .all ? "antenna.radiowaves.left.and.right" : "magnifyingglass")
                .font(.system(size: 24, weight: .light))
                .foregroundColor(Theme.hairline)
            Text(emptyTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.ink)
            Text(emptyHint)
                .font(.system(size: 11.5))
                .foregroundColor(Theme.inkDim)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Button {
                haptic(.medium)
                store.refresh(notify: false) { translateTitles() }
            } label: {
                Text("立即抓一轮")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.bg)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Theme.ink)
                    .clipShape(Capsule())
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.vertical, 60)
    }

    private var emptyTitle: String {
        if !query.isEmpty { return "没有匹配「\(query)」的稿子" }
        switch filter {
        case .all: return "还没有抓到大盘消息"
        case .unread: return "全部读完了"
        case .saved: return "还没有收藏"
        default: return "该来源暂无条目"
        }
    }

    private var emptyHint: String {
        if !query.isEmpty { return "换个关键词，或点右上角 × 清空搜索" }
        if filter == .unread { return "下拉或等自动刷新，新稿会自动出现在最上面" }
        if filter == .saved { return "左滑任意一条，点「收藏」即可加入" }
        return "检查网络或 VPN；也可以在设置里确认两个源的健康度"
    }

    private var errorStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10)).foregroundColor(.red)
            Text(store.lastError)
                .font(.system(size: 10.5)).foregroundColor(Theme.inkDim).lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }

    private var colophon: some View {
        VStack(spacing: 6) {
            Hairline().padding(.top, 10)
            Kicker(text: "本机直连 · 无第三方服务器 · \(TimeFmt.fullText(store.lastCheck)) 更新",
                   size: 8)
                .padding(.top, 10)
            Kicker(text: "点右上角放大镜搜索；长按任意一条可收藏、标记已读或分享", size: 8)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    // MARK: - 行为

    private func pull() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            store.refresh {
                translateTitles()
                cont.resume()
            }
        }
    }

    private func share(_ item: FeedItem) {
        var parts: [String] = []
        let zh = item.titleZh.isEmpty ? item.title : item.titleZh
        parts.append(zh)
        if !item.titleZh.isEmpty, item.titleZh != item.title { parts.append(item.title) }
        if !item.summary.isEmpty { parts.append(item.summary) }
        parts.append("原文：" + item.url)
        parts.append("—— 来自「彭博与路透新闻」· " + TimeFmt.feedText(item.ts) + " 北京时间")
        shareItems = [parts.joined(separator: "\n\n")]
        if let u = URL(string: item.url) { shareItems.append(u) }
        showShare = true
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    // MARK: - 标题中文化

    private func translateTitles() {
        guard Settings.zhMode == "sys" else { return }
        guard !titleBusy else { return }
        let todo = Array(store.items.filter { $0.titleZh.isEmpty }.prefix(25))
        guard !todo.isEmpty else { return }
        titleIds = todo.map { $0.id }
        titleTexts = todo.map { $0.title }
        titleResults = []
        titleBusy = true
        titleNonce += 1
        activeNonce = titleNonce
    }

    private func applyTitles(_ zh: [String]) {
        guard activeNonce == titleNonce else { return }
        guard !titleIds.isEmpty, zh.count == titleIds.count else { return }
        for (i, id) in titleIds.enumerated() where i < zh.count {
            let t = zh[i].trimmed
            guard !t.isEmpty else { continue }
            let srcLen = titleTexts.indices.contains(i) ? titleTexts[i].count : 0
            if srcLen > 24 && t.count < 6 { continue }
            Library.shared.setTitleZh(id, t)
        }
        store.items = Library.shared.items
        titleIds = []
        titleTexts = []
        titleResults = []
        titleBusy = false
        store.notifyPending()
        // 连续补翻：还有英文标题就继续下一批（最多 3 批，避免长时间占用）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            translateTitles()
        }
    }
}

// MARK: - 行

struct FeedRow: View {
    let item: FeedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                if !item.read {
                    Circle().fill(Theme.orange).frame(width: 5, height: 5)
                }
                SourceTag(site: item.site.rawValue)
                Kicker(text: TimeFmt.feedText(item.ts) + " 北京", size: 8.5)
                if Int(Date().timeIntervalSince1970) - item.arrivedTs < 1800 {
                    Text("NEW")
                        .font(.system(size: 7.5, weight: .black))
                        .tracking(0.8)
                        .foregroundColor(Theme.bg)
                        .padding(.horizontal, 3.5).padding(.vertical, 1.2)
                        .background(Theme.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                }
                Spacer()
                if item.saved {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 8)).foregroundColor(Theme.orange)
                }
                if item.fetched {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 8)).foregroundColor(Theme.hairline)
                }
            }

            Text(item.titleZh.isEmpty ? item.title : item.titleZh)
                .font(.editorial(18))
                .foregroundColor(item.read ? Theme.inkDim : Theme.ink)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if !item.titleZh.isEmpty {
                Text(item.title)
                    .font(.system(size: 10.5))
                    .foregroundColor(Theme.hairline)
                    .lineLimit(1)
            }

            if !item.summary.isEmpty {
                Text(item.summary)
                    .font(.system(size: 11.5))
                    .foregroundColor(Theme.inkDim)
                    .lineSpacing(2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !item.author.isEmpty {
                Kicker(text: item.author.uppercased(), color: Theme.hairline, size: 7.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

extension String {
    var trimmedLower: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
