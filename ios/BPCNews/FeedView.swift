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
    @AppStorage("notif_authorized") private var notifAuthorized: Bool = true

    // 快捷筛选
    @State private var query = ""
    @State private var filter: FeedFilter = .all
    @State private var showSearch = false
    @State private var shareItems: [Any] = []
    @State private var showShare = false

    // 标题中文化（TranslateService 驱动，与视图生命周期解耦）
    @State private var titleBusy = false
    @State private var titleTried: Set<String> = []
    @State private var visibleIds: Set<String> = []

    private let openItem = NotificationCenter.default.publisher(for: .bpcOpenItem)
    @Environment(\.scenePhase) private var scenePhase

    var body: some View { content }

    private var content: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    Theme.bg.ignoresSafeArea()

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            masthead.id("top")
                            metricsStrip
                            quickBar
                            if !notifAuthorized { notifStrip }
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
                                    .simultaneousGesture(TapGesture().onEnded {
                                        if !item.read { store.markRead(item.id) }
                                    })
                                    .onAppear {
                                        visibleIds.insert(item.id)
                                        translateSoon()
                                    }
                                    .contextMenu {
                                        Button {
                                            store.toggleSaved(item.id)
                                            haptic(.light)
                                        } label: {
                                            Label(item.saved ? "取消收藏" : "收藏",
                                                  systemImage: item.saved ? "bookmark.slash" : "bookmark")
                                        }
                                        Button {
                                            store.markRead(item.id)
                                            haptic(.light)
                                        } label: {
                                            Label(item.read ? "标记未读" : "标记已读",
                                                  systemImage: item.read ? "circle" : "checkmark.circle")
                                        }
                                        Button { share(item) } label: {
                                            Label("分享", systemImage: "square.and.arrow.up")
                                        }
                                    }
                                    Hairline().padding(.leading, 18)
                                }
                            }
                            colophon
                        }
                        .padding(.bottom, 96)
                    }
                    .refreshable { await pull() }

                    scrollTopButton(proxy)
                        .padding(.trailing, 16)
                        .padding(.bottom, 26)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { ReaderView(itemId: $0) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showOnboarding) { OnboardingView() }
            .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    store.startMonitoring()
                    store.refresh {
                        titleTried.removeAll()
                        translateTitles()
                    }
                }
            }
            .onChange(of: store.items.count) { _ in translateTitles() }
            .onChange(of: store.newItemsToken) { _ in translateTitles() }
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

    // MARK: - 一键到顶（苹果玻璃质感）

    private func scrollTopButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            haptic(.light)
            withAnimation(.easeOut(duration: 0.34)) { proxy.scrollTo("top", anchor: .top) }
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.ink)
                .frame(width: 48, height: 48)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().fill(Theme.bg.opacity(0.26)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6))
                .shadow(color: .black.opacity(0.45), radius: 12, y: 5)
        }
        .accessibilityLabel("回到顶部")
    }

    // MARK: - 顶部

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("彭博与路透新闻")
                        .font(.system(size: 20, weight: .heavy))
                        .tracking(1.2)
                        .foregroundColor(Theme.ink)
                    HStack(spacing: 6) {
                        Kicker(text: "BLOOMBERG · REUTERS", size: 8.5)
                        countdownPill
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Button { showSearch.toggle() } label: {
                        Image(systemName: showSearch ? "xmark" : "magnifyingglass")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(showSearch ? Theme.orange : Theme.ink)
                            .frame(width: 30, height: 30)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    Button {
                        haptic(.medium)
                        store.refresh(notify: true) { translateTitles() }
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
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.ink)
                            .frame(width: 30, height: 30)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(store.lastError.isEmpty ? Theme.orange : Color.red)
                    .frame(width: 5, height: 5)
                Kicker(text: store.latencyText, size: 8.5)
                Spacer()
                Kicker(text: "\(store.items.count) 条 · 未读 \(unreadCount)", size: 8.5)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var unreadCount: Int { store.items.filter { !$0.read }.count }

    /// 下一次自动刷新倒计时
    private var countdownPill: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let interval = max(15, Settings.pollSeconds)
            let elapsed = Int(ctx.date.timeIntervalSince1970) - store.lastCheck
            let left = max(0, interval - elapsed)
            HStack(spacing: 3) {
                Circle()
                    .fill(store.loading ? Theme.orange : Theme.hairline)
                    .frame(width: 3.5, height: 3.5)
                Text(store.loading ? "更新中" : "\(left)s")
                    .font(.mono(9))
                    .foregroundColor(store.loading ? Theme.orange : Theme.inkDim)
            }
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Theme.surface)
            .clipShape(Capsule())
        }
    }

    // MARK: - 指标区

    private var metricsStrip: some View {
        HStack(spacing: 0) {
            metric("彭博延迟", latencyText(store.bbgLatency), ok: store.bbgLatency >= 0 && store.bbgLatency < 3600)
            metricDivider
            metric("路透延迟", latencyText(store.rtrLatency), ok: store.rtrLatency >= 0 && store.rtrLatency < 3600)
            metricDivider
            metric("未读", "\(unreadCount)", ok: true)
            metricDivider
            metric("本轮", store.lastRoundMs >= 0
                    ? String(format: "%.1fs", Double(store.lastRoundMs) / 1000) : "—",
                   ok: store.lastRoundMs >= 0)
        }
        .padding(.vertical, 9)
        .background(Theme.surface.opacity(0.55))
        .overlay(Hairline(), alignment: .top)
        .overlay(Hairline(), alignment: .bottom)
        .padding(.bottom, 10)
    }

    private func latencyText(_ s: Int) -> String {
        if s < 0 { return "—" }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }

    private func metric(_ label: String, _ value: String, ok: Bool) -> some View {
        VStack(spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 7.5, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(Theme.hairline)
            HStack(spacing: 3) {
                Circle().fill(ok ? Theme.orange : Color.red).frame(width: 3.5, height: 3.5)
                Text(value).font(.mono(13)).foregroundColor(Theme.ink)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var metricDivider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 22)
    }

    // MARK: - 快捷栏

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
        case .unread: return unreadCount
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

    // MARK: - 骨架 / 空态 / 提示条

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
            Image(systemName: query.isEmpty && filter == .all
                  ? "antenna.radiowaves.left.and.right" : "magnifyingglass")
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
                store.refresh(notify: true) { translateTitles() }
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
        if filter == .unread { return "等自动刷新，新稿会自动出现在最上面" }
        if filter == .saved { return "长按任意一条，点「收藏」即可加入" }
        return "检查网络或 VPN；也可以在设置里确认两个源的健康度"
    }

    private var notifStrip: some View {
        Button {
            if let u = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(u)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 10)).foregroundColor(Theme.orange)
                Text("通知未开启，点此去系统设置打开")
                    .font(.system(size: 10.5)).foregroundColor(Theme.inkDim)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold)).foregroundColor(Theme.hairline)
            }
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(Theme.orange.opacity(0.10))
        }
        .buttonStyle(.plain)
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
            Kicker(text: "本机直连 · 无第三方服务器 · \(TimeFmt.fullText(store.lastCheck)) 更新", size: 8)
                .padding(.top, 10)
            Kicker(text: "点右上角放大镜搜索；长按任意一条可收藏、标记已读或分享", size: 8)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    // MARK: - 行为

    private func pull() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            store.refresh(notify: true) {
                titleTried.removeAll()
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

    // MARK: - 标题中文化（TranslateService）

    private func translateSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { translateTitles() }
    }

    private func translateTitles() {
        guard !titleBusy else { return }

        let pool = store.items.filter { $0.titleZh.isEmpty && !titleTried.contains($0.id) }
        guard !pool.isEmpty else {
            dictFill()
            return
        }

        let visibleFirst = pool.filter { visibleIds.contains($0.id) }
        let rest = pool.filter { !visibleIds.contains($0.id) }
        let batch = Array((visibleFirst + rest).prefix(40))
        guard !batch.isEmpty else { return }

        for it in batch { titleTried.insert(it.id) }
        if titleTried.count > 1200 { titleTried = Set(titleTried.suffix(600)) }

        titleBusy = true
        let texts = batch.map { $0.title }
        TranslateService.shared.translate(texts) { results, _ in
            for (i, it) in batch.enumerated() where i < results.count {
                let t = results[i].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, t != it.title else { continue }
                Library.shared.setTitleZh(it.id, t)
            }
            store.items = Library.shared.items
            titleBusy = false
            store.notifyPending()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { translateTitles() }
        }
    }

    private func dictFill() {
        var changed = false
        for it in store.items where it.titleZh.isEmpty {
            let zh = Dict.translate(it.title)
            if !zh.isEmpty, zh != it.title {
                Library.shared.setTitleZh(it.id, zh)
                changed = true
            }
        }
        if changed { store.items = Library.shared.items }
        store.notifyPending()
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
