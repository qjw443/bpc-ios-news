import SwiftUI
import WebKit

// MARK: - 模型

struct ResearchItem: Identifiable, Hashable {
    let id: String
    let title: String
    let org: String
    let date: String        // yyyy-MM-dd
    let url: String
    let kind: String        // bank / asset / filing / analyst / market / paper
    var titleZh: String = ""

    var kindLabel: String {
        switch kind {
        case "bank": return "投行"
        case "asset": return "资管"
        case "filing": return "披露"
        case "analyst": return "分析师"
        case "market": return "市场"
        case "paper": return "论文"
        case "pdf": return "PDF"
        default: return "研究"
        }
    }
}

enum ResearchKind: String, CaseIterable, Identifiable {
    case all, pdf, bank, asset, filing, analyst, market, paper
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .pdf: return "PDF研报"
        case .bank: return "投行"
        case .asset: return "资管"
        case .filing: return "披露"
        case .analyst: return "分析师"
        case .market: return "市场"
        case .paper: return "论文"
        }
    }
}

// MARK: - Store（纯美股来源）

final class ResearchStore: ObservableObject {

    static let shared = ResearchStore()

    @Published var items: [ResearchItem] = []
    @Published var loading = false
    @Published var error = ""
    @Published var lastUpdate: Date?

    private var fetching = false

    /// SEC 要求 UA 里带联系方式，否则 403
    private let secUA = "BPCNews/1.0 (US equity research reader; contact: bpc@example.com)"
    private let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 22
        c.httpAdditionalHeaders = ["Accept-Language": "en-US,en;q=0.9"]
        return URLSession(configuration: c)
    }()

    // MARK: 入口

    func refresh(completion: (() -> Void)? = nil) {
        guard !fetching else { completion?(); return }
        fetching = true
        loading = true
        error = ""

        let group = DispatchGroup()
        let lock = NSLock()
        var all: [ResearchItem] = []

        func add(_ list: [ResearchItem]) {
            lock.lock(); all.append(contentsOf: list); lock.unlock()
        }

        // ① 投行 / 资管观点（HTML 列表抓取）
        let pages: [(String, String, String, String)] = [
            // name, url, kind, href 过滤关键字
            ("Morgan Stanley", "https://www.morganstanley.com/ideas", "bank", "/ideas/"),
            ("Goldman Sachs", "https://www.goldmansachs.com/insights", "bank", "/insights/"),
            ("BlackRock BII", "https://www.blackrock.com/corporate/insights/blackrock-investment-institute", "asset", "/insights/"),
        ]
        for (org, url, kind, key) in pages {
            group.enter()
            fetchHTMLList(org: org, pageURL: url, kind: kind, hrefKey: key) { list in
                add(list); group.leave()
            }
        }

        // ② SEC EDGAR：8-K 重大事项 + 13F 机构持仓（官方 Atom）
        let feeds: [(String, String, String)] = [
            ("SEC 8-K", "https://www.sec.gov/cgi-bin/browse-edgar?action=getcurrent&type=8-K&owner=include&count=40&output=atom", "filing"),
            ("SEC 13F", "https://www.sec.gov/cgi-bin/browse-edgar?action=getcurrent&type=13F-HR&owner=include&count=40&output=atom", "filing"),
        ]
        for (org, url, kind) in feeds {
            group.enter()
            fetchAtom(org: org, url: url, kind: kind, userAgent: secUA) { list in
                add(list); group.leave()
            }
        }

        // ③ 分析师 / 市场 RSS
        let rss: [(String, String, String)] = [
            ("Seeking Alpha", "https://seekingalpha.com/market_currents.xml", "analyst"),
            ("Nasdaq Markets", "https://www.nasdaq.com/feed/rssoutbound?category=Markets", "market"),
            ("CNBC Finance", "https://search.cnbc.com/rs/search/combinedcms/view.xml?partnerId=wrss01&id=10000664", "market"),
        ]
        for (org, url, kind) in rss {
            group.enter()
            fetchRSS(org: org, url: url, kind: kind) { list in
                add(list); group.leave()
            }
        }

        // ④ 美联储/纽联储 PDF 研究
        group.enter()
        fetchNYFed { list in add(list); group.leave() }

        // ⑤ 量化论文
        group.enter()
        fetchArxiv { list in add(list); group.leave() }

        group.notify(queue: .main) {
            var seen = Set<String>()
            var merged: [ResearchItem] = []
            for it in all {
                let key = it.kind + "|" + it.title.lowercased()
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
                self.error = "美股研究源连接失败（可能被网络拦截），稍后重试或挂美国节点"
            }
            self.translateTitles()
            completion?()
        }
    }

    // MARK: HTML 列表（投行 / 资管公开观点）

    private func fetchHTMLList(org: String, pageURL: String, kind: String, hrefKey: String,
                               done: @escaping ([ResearchItem]) -> Void) {
        guard let url = URL(string: pageURL) else { done([]); return }
        var req = URLRequest(url: url, timeoutInterval: 22)
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,*/*", forHTTPHeaderField: "Accept")

        session.dataTask(with: req) { data, _, _ in
            guard let data = data, let html = String(data: data, encoding: .utf8) else {
                done([])
                return
            }
            var out: [ResearchItem] = []
            var seen = Set<String>()
            let re = try? NSRegularExpression(
                pattern: #"<a[^>]+href="([^"]+)"[^>]*>([\s\S]{5,400}?)</a>"#,
                options: [.caseInsensitive])

            let ns = html as NSString
            let range = NSRange(location: 0, length: ns.length)
            re?.enumerateMatches(in: html, options: [], range: range) { m, _, _ in
                guard let m = m, m.numberOfRanges >= 3,
                      let hrefR = Range(m.range(at: 1), in: html),
                      let textR = Range(m.range(at: 2), in: html) else { return }
                var href = String(html[hrefR])
                let raw = String(html[textR])
                let text = raw.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmed
                guard text.count >= 28, text.count <= 200 else { return }
                guard href.contains(hrefKey) || href.hasSuffix(".pdf") else { return }
                if href.hasPrefix("/") { href = "https://" + (URL(string: pageURL)?.host ?? "") + href }
                guard href.hasPrefix("http") else { return }
                if seen.contains(href) { return }
                seen.insert(href)
                out.append(ResearchItem(id: "h_" + href.md5ish, title: text, org: org,
                                        date: Self.todayString(), url: href, kind: kind))
            }
            done(Array(out.prefix(12)))
        }.resume()
    }

    // MARK: Atom（SEC EDGAR）

    private func fetchAtom(org: String, url: String, kind: String, userAgent: String,
                           done: @escaping ([ResearchItem]) -> Void) {
        guard let u = URL(string: url) else { done([]); return }
        var req = URLRequest(url: u, timeoutInterval: 22)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/atom+xml,application/xml,text/xml,*/*", forHTTPHeaderField: "Accept")

        session.dataTask(with: req) { data, _, _ in
            guard let data = data, let xml = String(data: data, encoding: .utf8) else {
                done([])
                return
            }
            var out: [ResearchItem] = []
            let chunks = xml.components(separatedBy: "<entry>")
            for chunk in chunks.dropFirst().prefix(40) {
                let title = Self.xml(chunk, "title")?
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmed ?? ""
                var link = ""
                if let r = chunk.range(of: #"<link[^>]+href="([^"]+)""#, options: .regularExpression) {
                    let seg = String(chunk[r])
                    if let h = seg.range(of: #"href="([^"]+)""#, options: .regularExpression) {
                        link = String(seg[h]).replacingOccurrences(of: "href=\"", with: "")
                            .replacingOccurrences(of: "\"", with: "")
                    }
                }
                let updated = Self.xml(chunk, "updated") ?? ""
                guard !title.isEmpty else { continue }
                out.append(ResearchItem(id: "s_" + (link.isEmpty ? title.md5ish : link.md5ish),
                                        title: title, org: org,
                                        date: String(updated.prefix(10)).isEmpty ? Self.todayString() : String(updated.prefix(10)),
                                        url: link.isEmpty ? url : link, kind: kind))
            }
            done(out)
        }.resume()
    }

    // MARK: RSS

    private func fetchRSS(org: String, url: String, kind: String,
                          done: @escaping ([ResearchItem]) -> Void) {
        guard let u = URL(string: url) else { done([]); return }
        var req = URLRequest(url: u, timeoutInterval: 20)
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: req) { data, _, _ in
            guard let data = data, let xml = String(data: data, encoding: .utf8) else {
                done([])
                return
            }
            var out: [ResearchItem] = []
            for chunk in xml.components(separatedBy: "<item>").dropFirst().prefix(30) {
                let title = (Self.xml(chunk, "title") ?? "")
                    .replacingOccurrences(of: "<!\\[CDATA\\[|\\]\\]>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmed
                let link = Self.xml(chunk, "link") ?? ""
                let date = Self.parseRFC822(Self.xml(chunk, "pubDate") ?? "")
                guard title.count > 20, !link.isEmpty else { continue }
                out.append(ResearchItem(id: "r_" + link.md5ish, title: title, org: org,
                                        date: date, url: link, kind: kind))
            }
            done(out)
        }.resume()
    }

    // MARK: 纽约联储 Staff Reports（真 PDF 直链）

    private func fetchNYFed(done: @escaping ([ResearchItem]) -> Void) {
        guard let url = URL(string: "https://www.newyorkfed.org/research/staff_reports") else {
            done([]); return
        }
        var req = URLRequest(url: url, timeoutInterval: 22)
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: req) { data, _, _ in
            guard let data = data, let html = String(data: data, encoding: .utf8) else {
                done([]); return
            }
            var out: [ResearchItem] = []
            var seen = Set<String>()
            // 列表里出现 sr12345 → 直链 /medialibrary/media/research/staff_reports/sr12345.pdf
            let re = try? NSRegularExpression(pattern: #"staff_reports/sr(\d{3,5})"#, options: [])
            let ns = html as NSString
            re?.enumerateMatches(in: html, options: [], range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m = m, m.numberOfRanges > 1,
                      let r = Range(m.range(at: 1), in: html) else { return }
                let num = String(html[r])
                if seen.contains(num) { return }
                seen.insert(num)
                let pdf = "https://www.newyorkfed.org/medialibrary/media/research/staff_reports/sr\(num).pdf"
                out.append(ResearchItem(id: "nyfed_\(num)",
                                        title: "NY Fed Staff Report SR\(num)",
                                        org: "Federal Reserve Bank of New York",
                                        date: Self.todayString(),
                                        url: pdf, kind: "pdf"))
            }
            done(Array(out.prefix(12)))
        }.resume()
    }

    // MARK: arXiv

    private func fetchArxiv(done: @escaping ([ResearchItem]) -> Void) {
        let s = "http://export.arxiv.org/api/query?search_query=cat:q-fin.*&start=0&max_results=25&sortBy=submittedDate&sortOrder=descending"
        guard let url = URL(string: s) else { done([]); return }
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: req) { data, _, _ in
            guard let data = data, let xml = String(data: data, encoding: .utf8) else {
                done([])
                return
            }
            var out: [ResearchItem] = []
            for chunk in xml.components(separatedBy: "<entry>").dropFirst().prefix(25) {
                let title = (Self.xml(chunk, "title") ?? "")
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmed
                let idURL = Self.xml(chunk, "id") ?? ""
                let published = Self.xml(chunk, "published") ?? ""
                guard title.count > 15, !idURL.isEmpty else { continue }
                let pdf = idURL.replacingOccurrences(of: "http://arxiv.org/abs/", with: "https://arxiv.org/pdf/")
                out.append(ResearchItem(id: "ax_" + idURL.md5ish, title: title, org: "arXiv q-fin",
                                        date: String(published.prefix(10)),
                                        url: pdf, kind: "pdf"))
            }
            done(out)
        }.resume()
    }

    // MARK: 标题中文化

    @Published var translating = false

    /// 供界面定时调用：每轮把还没中文的标题翻一批（持续追上）
    func translatePendingTitles() {
        guard !translating else { return }
        translateTitles()
    }

    private func translateTitles() {
        // 只翻「本身还是英文」且「还没中文」的条目
        let todo = items.filter { item in
            !TextQuality.isTranslated(item.title) && !TextQuality.isTranslatedLoose(item.titleZh)
        }
        guard !todo.isEmpty else { return }
        translating = true
        let batch = Array(todo.prefix(40))
        TranslateService.shared.translate(batch.map { $0.title }) { zh, _ in
            for (i, it) in batch.enumerated() where i < zh.count {
                var t = zh[i].trimmingCharacters(in: .whitespacesAndNewlines)
                // 兜底清洗：万一上游还带 URL 编码残留
                t = t.replacingOccurrences(of: "%20", with: " ")
                    .replacingOccurrences(of: "%2C", with: ",")
                    .replacingOccurrences(of: "%3A", with: ":")
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard TextQuality.isTranslatedLoose(t), t != it.title else { continue }
                if let idx = self.items.firstIndex(where: { $0.id == it.id }) {
                    self.items[idx].titleZh = t
                }
            }
            self.translating = false
        }
    }

    // MARK: 工具

    private static func xml(_ s: String, _ tag: String) -> String? {
        guard let a = s.range(of: "<\(tag)"), let b = s.range(of: "</\(tag)>", range: a.upperBound..<s.endIndex) else { return nil }
        var body = String(s[a.upperBound..<b.lowerBound])
        if let gt = body.firstIndex(of: ">") { body = String(body[body.index(after: gt)...]) }
        return body.trimmed
    }

    private static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "America/New_York")
        return f.string(from: Date())
    }

    private static func parseRFC822(_ s: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let d = f.date(from: s.trimmed) {
            let o = DateFormatter()
            o.dateFormat = "yyyy-MM-dd"
            o.timeZone = TimeZone(identifier: "America/New_York")
            return o.string(from: d)
        }
        return todayString()
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
                        Text("正在拉取美股研究…")
                            .font(.system(size: 11)).foregroundColor(Theme.inkDim).padding(.top, 10)
                        Spacer()
                    } else if filtered.isEmpty {
                        Spacer()
                        Text(store.error.isEmpty ? "暂无内容" : store.error)
                            .font(.system(size: 12)).foregroundColor(Theme.inkDim)
                            .multilineTextAlignment(.center).padding(.horizontal, 40)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(filtered) { item in
                                    NavigationLink(value: item) { row(item) }
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
        .onAppear { if store.items.isEmpty { store.refresh() } }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            store.translatePendingTitles()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("美股研究")
                    .font(.system(size: 20, weight: .heavy)).tracking(1.2)
                    .foregroundColor(Theme.ink)
                HStack(spacing: 6) {
                    Kicker(text: "WALL ST · SEC · ARXIV", size: 8.5)
                    if let t = store.lastUpdate {
                        Kicker(text: TimeFmt.feedText(Int(t.timeIntervalSince1970)), size: 8.5)
                    }
                }
            }
            Spacer()
            Button { store.refresh() } label: {
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
                    .background(tagColor(item.kind))
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                Kicker(text: item.date, size: 8.5)
                Spacer()
                Kicker(text: item.org, color: Theme.inkDim, size: 8.5)
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
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func tagColor(_ kind: String) -> Color {
        switch kind {
        case "pdf": return Color(red: 0.72, green: 0.18, blue: 0.18)
        case "bank": return Color(red: 0.12, green: 0.32, blue: 0.72)
        case "asset": return Color(red: 0.10, green: 0.48, blue: 0.42)
        case "filing": return Color(red: 0.45, green: 0.30, blue: 0.62)
        case "analyst": return Theme.orange
        case "paper": return Color(red: 0.35, green: 0.55, blue: 0.95)
        default: return Color(red: 0.35, green: 0.35, blue: 0.38)
        }
    }

    private func pull() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            store.refresh { c.resume() }
        }
    }
}

// MARK: - 详情

struct ResearchDocView: View {
    let item: ResearchItem
    @Environment(\.dismiss) private var dismiss
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
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Theme.ink)
                            .frame(width: 30, height: 30)
                            .background(Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
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
        .navigationBarBackButtonHidden(true)
        .onAppear { ctl.load() }
        .onChange(of: ctl.ready) { ok in
            guard ok else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { translate() }
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            guard ctl.ready, !busy, rounds < 200 else { return }
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

// MARK: - 工具

extension String {
    var md5ish: String {
        var h: UInt64 = 1469598103934665603
        for b in self.utf8 {
            h ^= UInt64(b)
            h = h &* 1099511628211
        }
        return String(h, radix: 16)
    }
}
