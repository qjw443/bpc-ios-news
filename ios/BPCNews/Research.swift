import SwiftUI
import WebKit

// MARK: - 模型

struct ResearchItem: Identifiable, Hashable {
    let id: String
    let title: String
    let org: String
    let date: String        // yyyy-MM-dd
    let url: String
    let kind: String        // stock / industry / strategy / macro / paper
    var titleZh: String = ""

    var kindLabel: String {
        switch kind {
        case "stock": return "个股"
        case "industry": return "行业"
        case "strategy": return "策略"
        case "macro": return "宏观"
        case "paper": return "论文"
        default: return "研报"
        }
    }
}

enum ResearchKind: String, CaseIterable, Identifiable {
    case all, stock, industry, strategy, macro, paper
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .stock: return "个股"
        case .industry: return "行业"
        case .strategy: return "策略"
        case .macro: return "宏观"
        case .paper: return "论文"
        }
    }
}

// MARK: - Store

final class ResearchStore: ObservableObject {

    static let shared = ResearchStore()

    @Published var items: [ResearchItem] = []
    @Published var loading = false
    @Published var error = ""
    @Published var lastUpdate: Date?

    private var fetching = false

    /// 东方财富研报中心（免费 JSON）：0 个股 / 1 行业 / 2 策略 / 3 宏观
    private let eastmoneyTypes = [("0", "stock"), ("1", "industry"), ("2", "strategy"), ("3", "macro")]
    private let detailPath = ["stock": "zw_stock", "industry": "zw_industry",
                              "strategy": "zw_strategy", "macro": "zw_macresearch"]

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            "Referer": "https://data.eastmoney.com/report/",
            "Accept": "application/json,text/plain,*/*",
        ]
        return URLSession(configuration: c)
    }()

    func refresh(completion: (() -> Void)? = nil) {
        guard !fetching else { completion?(); return }
        fetching = true
        loading = true
        error = ""

        let group = DispatchGroup()
        let lock = NSLock()
        var collected: [ResearchItem] = []
        var failures = 0

        for (qType, kind) in eastmoneyTypes {
            group.enter()
            fetchEastmoney(qType: qType, kind: kind) { list in
                lock.lock()
                if list.isEmpty { failures += 1 } else { collected.append(contentsOf: list) }
                lock.unlock()
                group.leave()
            }
        }

        group.enter()
        fetchArxiv { list in
            lock.lock(); collected.append(contentsOf: list); lock.unlock()
            group.leave()
        }

        group.notify(queue: .main) {
            var seen = Set<String>()
            var merged: [ResearchItem] = []
            for it in collected {
                let key = it.kind + "|" + it.title
                if seen.contains(key) { continue }
                seen.insert(key)
                merged.append(it)
            }
            merged.sort { $0.date > $1.date }
            self.items = Array(merged.prefix(300))
            self.loading = false
            self.fetching = false
            self.lastUpdate = Date()
            if self.items.isEmpty {
                self.error = failures >= self.eastmoneyTypes.count
                    ? "研报源连接失败（东财接口可能需要代理），请稍后重试"
                    : "暂时没有取到研报"
            }
            self.translatePaperTitles()
            completion?()
        }
    }

    // MARK: 东方财富

    private func fetchEastmoney(qType: String, kind: String, done: @escaping ([ResearchItem]) -> Void) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let end = df.string(from: Date())
        let begin = df.string(from: Date().addingTimeInterval(-14 * 86400))

        var comps = URLComponents(string: "https://reportapi.eastmoney.com/report/list")!
        comps.queryItems = [
            .init(name: "industryCode", value: "*"),
            .init(name: "pageSize", value: "40"),
            .init(name: "industry", value: "*"),
            .init(name: "rating", value: ""),
            .init(name: "ratingChange", value: ""),
            .init(name: "beginTime", value: begin),
            .init(name: "endTime", value: end),
            .init(name: "pageNo", value: "1"),
            .init(name: "fields", value: ""),
            .init(name: "qType", value: qType),
            .init(name: "orgCode", value: ""),
            .init(name: "code", value: "*"),
            .init(name: "rcode", value: ""),
            .init(name: "p", value: "1"),
            .init(name: "pageNum", value: "1"),
            .init(name: "pageNumber", value: "1"),
        ]
        guard let url = comps.url else { done([]); return }

        session.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = obj["data"] as? [[String: Any]] else {
                done([])
                return
            }
            var out: [ResearchItem] = []
            for row in rows {
                guard let title = (row["title"] as? String)?.trimmed, !title.isEmpty else { continue }
                let org = (row["orgSName"] as? String) ?? ""
                let rawDate = (row["publishDate"] as? String) ?? ""
                let date = String(rawDate.prefix(10))
                let encode = (row["encodeUrl"] as? String) ?? ""
                let infoCode = (row["infoCode"] as? String) ?? ""
                let path = self.detailPath[kind] ?? "zw_stock"
                let urlStr: String
                if !encode.isEmpty {
                    urlStr = "https://data.eastmoney.com/report/\(path).jshtml?encodeUrl=\(encode)"
                } else {
                    urlStr = "https://data.eastmoney.com/report/\(path).jshtml?infocode=\(infoCode)"
                }
                let id = "em_" + (infoCode.isEmpty ? title.md5ish : infoCode)
                out.append(ResearchItem(id: id, title: title, org: org, date: date,
                                        url: urlStr, kind: kind))
            }
            done(out)
        }.resume()
    }

    // MARK: arXiv（量化金融最新论文）

    private func fetchArxiv(done: @escaping ([ResearchItem]) -> Void) {
        let s = "http://export.arxiv.org/api/query?search_query=cat:q-fin.*&start=0&max_results=30&sortBy=submittedDate&sortOrder=descending"
        guard let url = URL(string: s) else { done([]); return }
        session.dataTask(with: url) { data, _, _ in
            guard let data = data, let xml = String(data: data, encoding: .utf8) else {
                done([])
                return
            }
            var out: [ResearchItem] = []
            let entries = xml.components(separatedBy: "<entry>")
            for chunk in entries.dropFirst() {
                let title = Self.pick(chunk, "title")?.replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "  ", with: " ").trimmed ?? ""
                let published = Self.pick(chunk, "published") ?? ""
                let idURL = Self.pick(chunk, "id") ?? ""
                guard !title.isEmpty, !idURL.isEmpty else { continue }
                let date = String(published.prefix(10))
                out.append(ResearchItem(id: "ax_" + idURL.md5ish, title: title,
                                        org: "arXiv q-fin", date: date,
                                        url: idURL, kind: "paper"))
            }
            done(Array(out.prefix(30)))
        }.resume()
    }

    private static func pick(_ s: String, _ tag: String) -> String? {
        guard let a = s.range(of: "<\(tag)"), let b = s.range(of: "</\(tag)>", range: a.upperBound..<s.endIndex) else { return nil }
        var body = String(s[a.upperBound..<b.lowerBound])
        if let gt = body.firstIndex(of: ">") { body = String(body[body.index(after: gt)...]) }
        return body.trimmed
    }

    // MARK: 论文标题中文

    private func translatePaperTitles() {
        let papers = items.filter { $0.kind == "paper" && $0.titleZh.isEmpty }
        guard !papers.isEmpty else { return }
        let batch = Array(papers.prefix(20))
        TranslateService.shared.translate(batch.map { $0.title }) { zh, _ in
            var changed = false
            for (i, p) in batch.enumerated() where i < zh.count {
                let t = zh[i].trimmingCharacters(in: .whitespacesAndNewlines)
                guard TextQuality.isTranslated(t), t != p.title else { continue }
                if let idx = self.items.firstIndex(where: { $0.id == p.id }) {
                    self.items[idx].titleZh = t
                    changed = true
                }
            }
            _ = changed
        }
    }
}

// MARK: - 列表页

struct ResearchView: View {
    @StateObject private var store = ResearchStore.shared
    @State private var kind: ResearchKind = .all

    private var filtered: [ResearchItem] {
        kind == .all ? store.items : store.items.filter { $0.kind == kind.rawValue }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    chips
                    if store.loading && store.items.isEmpty {
                        Spacer()
                        ProgressView().tint(Theme.orange)
                        Text("正在拉取最新研报…")
                            .font(.system(size: 11)).foregroundColor(Theme.inkDim)
                            .padding(.top, 10)
                        Spacer()
                    } else if filtered.isEmpty {
                        Spacer()
                        Text(store.error.isEmpty ? "暂无研报" : store.error)
                            .font(.system(size: 12)).foregroundColor(Theme.inkDim)
                            .multilineTextAlignment(.center).padding(.horizontal, 40)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(filtered) { item in
                                    NavigationLink(value: item) {
                                        row(item)
                                    }
                                    .buttonStyle(.plain)
                                    Hairline().padding(.leading, 18)
                                }
                            }
                            .padding(.bottom, 30)
                        }
                        .refreshable { await pull() }
                    }
                }
            }
            .navigationDestination(for: ResearchItem.self) { ResearchDocView(item: $0) }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if store.items.isEmpty { store.refresh() }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("研报")
                    .font(.system(size: 20, weight: .heavy)).tracking(1.2)
                    .foregroundColor(Theme.ink)
                HStack(spacing: 6) {
                    Kicker(text: "东财 + ARXIV", size: 8.5)
                    if let t = store.lastUpdate {
                        Kicker(text: TimeFmt.feedText(Int(t.timeIntervalSince1970)) , size: 8.5)
                    }
                }
            }
            Spacer()
            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.ink)
                    .frame(width: 30, height: 30)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 10)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(ResearchKind.allCases) { k in
                    let n = k == .all ? store.items.count
                        : store.items.filter { $0.kind == k.rawValue }.count
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { kind = k }
                    } label: {
                        HStack(spacing: 4) {
                            Text(k.title)
                                .font(.system(size: 11, weight: kind == k ? .semibold : .regular))
                            if n > 0 {
                                Text("\(n)").font(.mono(9))
                                    .foregroundColor(kind == k ? Theme.bg.opacity(0.7) : Theme.inkDim)
                            }
                        }
                        .foregroundColor(kind == k ? Theme.bg : Theme.inkDim)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(kind == k ? Theme.ink : Theme.surface)
                        .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 18)
        }
        .padding(.bottom, 10)
    }

    private func row(_ item: ResearchItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text(item.kindLabel)
                    .font(.system(size: 8.5, weight: .black)).tracking(0.8)
                    .foregroundColor(Theme.bg)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(item.kind == "paper" ? Color(red: 0.35, green: 0.55, blue: 0.95) : Theme.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                Kicker(text: item.date, size: 8.5)
                Spacer()
                if item.kind != "paper" {
                    Kicker(text: item.org, color: Theme.inkDim, size: 8.5)
                }
            }
            Text(item.titleZh.isEmpty ? item.title : item.titleZh)
                .font(.editorial(16))
                .foregroundColor(Theme.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if !item.titleZh.isEmpty {
                Text(item.title)
                    .font(.system(size: 10.5))
                    .foregroundColor(Theme.hairline)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func pull() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            store.refresh { c.resume() }
        }
    }
}

// MARK: - 详情（网页 + 自动翻译）

struct ResearchDocView: View {
    let item: ResearchItem
    @StateObject private var ctl: WebPageController
    @State private var status = "加载中…"
    @State private var busy = false
    @State private var rounds = 0

    init(item: ResearchItem) {
        self.item = item
        _ctl = StateObject(wrappedValue: WebPageController(urlString: item.url))
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.kindLabel + " · " + item.org)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Theme.ink)
                        Kicker(text: item.date, size: 8)
                    }
                    Spacer()
                    Button {
                        if let u = URL(string: item.url) { UIApplication.shared.open(u) }
                    } label: {
                        Image(systemName: "safari")
                            .font(.system(size: 13)).foregroundColor(Theme.ink)
                            .frame(width: 30, height: 30)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                Divider().overlay(Theme.hairline)
                WebContainer(webView: ctl.webView)
                HStack(spacing: 6) {
                    Circle().fill(busy ? Theme.orange : Theme.hairline).frame(width: 4, height: 4)
                    Text(status).font(.system(size: 10)).foregroundColor(Theme.inkDim)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background(Theme.surface)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .onAppear { ctl.load() }
        .onChange(of: ctl.ready) { ok in
            guard ok else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { translate() }
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            guard ctl.ready, !busy, rounds < 40 else { return }
            translate()
        }
    }

    private func translate() {
        guard !busy else { return }
        busy = true
        rounds += 1
        ctl.webView.evaluateJavaScript(PageJS.collectTexts) { res, _ in
            guard let s = res as? String,
                  let d = s.data(using: .utf8),
                  let texts = try? JSONSerialization.jsonObject(with: d) as? [String],
                  !texts.isEmpty else {
                busy = false
                status = "已是中文"
                return
            }
            status = "翻译 \(texts.count) 段…"
            TranslateService.shared.translate(texts) { zh, src in
                let payload = (try? JSONSerialization.data(withJSONObject: zh)) ?? Data("[]".utf8)
                let js = "window.__bpcApplyTexts(" + (String(data: payload, encoding: .utf8) ?? "[]") + ");"
                ctl.webView.evaluateJavaScript(js) { _, _ in
                    busy = false
                    status = "已中文 \(zh.count) 段（\(src.rawValue)）"
                }
            }
        }
    }
}

// MARK: - 小工具

extension String {
    /// 稳定的短哈希（不用 CryptoKit，避免额外依赖）
    var md5ish: String {
        var h: UInt64 = 1469598103934665603
        for b in self.utf8 {
            h ^= UInt64(b)
            h = h &* 1099511628211
        }
        return String(h, radix: 16)
    }
}
