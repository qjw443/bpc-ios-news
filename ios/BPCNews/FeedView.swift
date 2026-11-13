import SwiftUI

struct FeedView: View {
    @EnvironmentObject private var store: FeedStore
    @State private var path: [String] = []
    @State private var showSettings = false

    private let ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private let openItem = NotificationCenter.default.publisher(for: .bpcOpenItem)

    var body: some View {
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
            .onReceive(ticker) { _ in store.refresh() }
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
                if store.items.isEmpty { store.refresh() }
            }
        }
        .tint(Theme.ink)
        .preferredColorScheme(.dark)
    }

    private func pull() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            store.refresh { cont.resume() }
        }
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                SourceTag(site: item.site.rawValue)
                Kicker(text: FeedRow.relative(item.ts), size: 9)
                Spacer()
                if item.fetched {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.hairline)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.hairline)
            }

            Text(item.titleZh.isEmpty ? item.title : item.titleZh)
                .font(.editorial(19))
                .foregroundColor(Theme.ink)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if !item.titleZh.isEmpty {
                Text(item.title)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.inkDim)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !item.brief.isEmpty {
                Text(item.brief.joined(separator: "　／　"))
                    .font(.system(size: 12.5))
                    .foregroundColor(Theme.inkDim)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 17)
        .contentShape(Rectangle())
    }

    static func relative(_ ts: Int) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(ts)),
                                 relativeTo: Date())
    }
}
