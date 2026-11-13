import Foundation
import UserNotifications
import UIKit
import Network

/// 编排层：发现 → 入库 → 抓正文（App 内 WKWebView 绕过付费墙）→ 本地通知
final class FeedStore: ObservableObject {

    static let shared = FeedStore()

    @Published var items: [FeedItem] = []
    @Published var loading = false
    @Published var status: String = ""
    @Published var lastError: String = ""

    private let discovery = Discovery()
    private var fetchers: [String: ArticleFetcher] = [:]
    private var busy = false
    private var roundCount = 0
    private let lastCheckKey = "last_discovery_ts"

    // 自动监控
    private var timer: Timer?
    private var pathMonitor: NWPathMonitor?      // NWPathMonitor 取消后不可复用，每次重建
    private var monitorStarted = false
    @Published var lastCheck: Int = UserDefaults.standard.integer(forKey: "last_check_ts")

    // 顶部延迟指标：各站「最新稿发布至今」的秒数，以及本轮发现耗时
    @Published var bbgLatency: Int = -1
    @Published var rtrLatency: Int = -1
    @Published var lastRoundMs: Int = -1

    var latencyText: String {
        func fmt(_ s: Int) -> String {
            if s < 0 { return "—" }
            if s < 60 { return "\(s) 秒" }
            if s < 3600 { return "\(s / 60) 分钟" }
            return "\(s / 3600) 小时"
        }
        var parts = ["彭博 \(fmt(bbgLatency))", "路透 \(fmt(rtrLatency))"]
        if lastRoundMs >= 0 { parts.append("本轮 \(String(format: "%.1f", Double(lastRoundMs) / 1000))s") }
        return parts.joined(separator: "　·　")
    }

    // MARK: 自动监控（不需要手动下拉）

    /// 前台定时轮询 + 网络恢复立即刷 + 回到前台立即刷
    func startMonitoring() {
        guard Settings.autoMonitor else { return }
        if timer == nil {
            let t = Timer(timeInterval: TimeInterval(Settings.pollSeconds), repeats: true) {
                [weak self] _ in
                self?.refresh()
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        if !monitorStarted {
            monitorStarted = true
            let m = NWPathMonitor()
            m.pathUpdateHandler = { [weak self] path in
                guard path.status == .satisfied else { return }
                DispatchQueue.main.async { self?.refresh() }
            }
            m.start(queue: DispatchQueue(label: "bpc.net.monitor"))
            pathMonitor = m
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        if monitorStarted {
            pathMonitor?.cancel()
            pathMonitor = nil
            monitorStarted = false
        }
    }

    var lastCheckText: String {
        guard lastCheck > 0 else { return "尚未检查" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(lastCheck)),
                                 relativeTo: Date())
    }

    // MARK: - 启动

    func bootstrap() {
        Library.shared.load()
        Library.shared.migrate()          // 清掉旧版第三方源留下的脏条目
        items = Library.shared.items
        status = "规则编译中…"
        PaywallEngine.shared.prepare { [weak self] in
            self?.status = "规则就绪（\(PaywallEngine.shared.compiledCount) 条）"
        }
    }

    /// 各发现源的最近一次结果（设置页展示）
    var sourceStatuses: [Discovery.SourceStatus] { discovery.statuses }

    // MARK: - 发现最新

    func refresh(notify: Bool = false, completion: (() -> Void)? = nil) {
        guard !busy else { completion?(); return }
        busy = true
        let roundStart = Date()
        DispatchQueue.main.async { self.loading = true; self.lastError = "" }

        // 看门狗：poll 不回调（网络挂住）时把状态复位，避免刷新键变死键
        var finished = false
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self, !finished else { return }
            finished = true
            self.busy = false
            DispatchQueue.main.async {
                self.loading = false
                self.lastError = "发现超时（50s），请重试"
                self.status = "超时"
            }
            completion?()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 50, execute: watchdog)

        roundCount += 1
        let full = (roundCount % 3 == 1)   // 每 3 轮做一次全量（sitemap + 路透兜底）
        discovery.poll(full: full) { [weak self] found in
            guard let self = self else { return }
            guard !finished else { return }
            finished = true
            watchdog.cancel()

            let enabled = Settings.enabledSites
            let cutoff = Date().addingTimeInterval(-Double(Settings.freshHours) * 3600)
            var mapped: [FeedItem] = []
            var skippedOld = 0

            for f in found where enabled.contains(f.site.rawValue) {
                // 时间窗：sitemap 会带出几十小时前的稿子，超出窗口直接丢
                let date = f.date ?? Date()
                if date < cutoff { skippedOld += 1; continue }

                let title = Self.cleanTitle(f.title)
                let low = title.lowercased()
                if title.count < 16 { continue }
                if ["bloomberg", "reuters", "bloomberg.com", "reuters.com"].contains(low) { continue }
                if low.hasPrefix("transcript") || low.hasPrefix("watch:") || low.hasPrefix("listen") { continue }

                let id = Hash.short(f.link + "|" + title)
                var item = FeedItem(id: id,
                                    site: f.site,
                                    title: title,
                                    url: f.link,
                                    ts: Int(date.timeIntervalSince1970))
                item.summary = f.summary
                item.author = f.author
                // 词典基线：先给一个中文（哪怕不完美），系统翻译随后覆盖更高质量的结果
                let baseline = Dict.translate(title)
                if !baseline.isEmpty { item.titleZh = baseline }
                if Settings.zhMode == "dict", !f.summary.isEmpty {
                    item.summary = Dict.translate(f.summary)
                }
                mapped.append(item)
            }

            let fresh = Library.shared.merge(mapped)
            let bbg = mapped.filter { $0.site == .bloomberg }.count
            let rtr = mapped.count - bbg

            // 顶部延迟：各站最新稿的发布时间距今多久；以及本轮发现耗时
            let nowTs = Int(Date().timeIntervalSince1970)
            let bbgNewest = Library.shared.items.filter { $0.site == .bloomberg }.map { $0.ts }.max() ?? 0
            let rtrNewest = Library.shared.items.filter { $0.site == .reuters }.map { $0.ts }.max() ?? 0
            let roundMs = Int(Date().timeIntervalSince(roundStart) * 1000)

            DispatchQueue.main.async {
                self.items = Library.shared.items
                self.loading = false
                self.busy = false
                if bbgNewest > 0 { self.bbgLatency = max(0, nowTs - bbgNewest) }
                if rtrNewest > 0 { self.rtrLatency = max(0, nowTs - rtrNewest) }
                self.lastRoundMs = roundMs
                var s = "彭博 \(bbg) · 路透 \(rtr) · 新增 \(fresh.count)"
                if skippedOld > 0 { s += " · 滤除旧闻 \(skippedOld)" }
                self.status = s
                self.lastCheck = Int(Date().timeIntervalSince1970)
                UserDefaults.standard.set(self.lastCheck, forKey: "last_check_ts")
                UserDefaults.standard.set(self.lastCheck, forKey: self.lastCheckKey)

                (UIApplication.shared.delegate as? AppDelegate)?.scheduleBackground()

                // 推送：前台等标题翻完再推（FeedView 调 notifyPending），后台这里直接推
                let pushCut = nowTs - Settings.pushWindowMinutes * 60
                let pushable = fresh.filter { $0.ts >= pushCut }
                if notify && !pushable.isEmpty {
                    if UIApplication.shared.applicationState == .active {
                        self.pendingNotify = pushable
                        // 兜底：无论翻译是否成功，4 秒后一定把待推送发出去
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                            self?.notifyPending()
                        }
                    } else {
                        self.notifyNew(pushable)
                    }
                }
            }
            completion?()
        }
    }

    // MARK: - 已读 / 收藏（统一入口：库与界面同时更新）

    func markRead(_ id: String) {
        Library.shared.markRead(id)
        items = Library.shared.items
    }

    func toggleSaved(_ id: String) {
        Library.shared.toggleSaved(id)
        items = Library.shared.items
    }

    // MARK: - 抓正文（App 内绕过付费墙）

    func fetch(item: FeedItem, silent: Bool = false, completion: ((Article?) -> Void)? = nil) {
        if let cached = Library.shared.article(for: item.id), cached.blocks.count >= 3 {
            completion?(cached)
            return
        }
        // 已在抓取中：保持加载态，不回调失败（否则用户二次点击会看到假错误）
        guard fetchers[item.id] == nil else { return }
        startFetch(item: item, silent: silent, completion: completion)
    }

    private func startFetch(item: FeedItem, silent: Bool,
                            completion: ((Article?) -> Void)?) {
        guard let url = URL(string: item.url) else { completion?(nil); return }
        let fetcher = ArticleFetcher()
        fetchers[item.id] = fetcher

        func run(botMode: Bool) {
            fetcher.start(url: url, site: item.site, botMode: botMode, onSuccess: { [weak self] art in
                guard let self = self else { return }
                var a = art
                a.id = item.id
                a.publishedTs = item.ts          // 发布时间随正文一起落盘（阅读页显示北京时间）
                Library.shared.markFetched(item.id, article: a)
                self.fetchers.removeValue(forKey: item.id)
                DispatchQueue.main.async {
                    self.items = Library.shared.items
                    if !silent { self.status = "已取稿：\(a.blocks.count) 段 · \(a.via)" }
                }
                completion?(a)
            }, onFail: { [weak self] err in
                guard let self = self else { return }
                if !botMode {
                    // 真 Chrome 指纹失手 → 退 Googlebot 模式再来一次
                    run(botMode: true)
                    return
                }
                self.fetchers.removeValue(forKey: item.id)
                DispatchQueue.main.async {
                    self.lastError = err.localizedDescription
                    self.status = "取稿失败"
                }
                completion?(nil)
            })
        }
        run(botMode: false)
    }

    /// 已翻译、待推送的前台新稿（等标题变中文后再弹通知）
    private var pendingNotify: [FeedItem] = []
    private var notifiedIds: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "notified_ids") ?? [])

    /// FeedView 在标题翻译完成后调用：此时标题已是中文，再弹通知
    func notifyPending() {
        guard !pendingNotify.isEmpty else { return }
        let todo = pendingNotify.filter { !notifiedIds.contains($0.id) }
        pendingNotify = []
        guard !todo.isEmpty else { return }
        notifyNew(Array(todo.prefix(3)))
    }

    // MARK: - 本地通知（无 APNs，全部在设备上）

    private func notifyNew(_ fresh: [FeedItem]) {
        guard let first = fresh.first else { return }
        for it in fresh { notifiedIds.insert(it.id) }
        if notifiedIds.count > 500 { notifiedIds = Set(notifiedIds.suffix(200)) }
        UserDefaults.standard.set(Array(notifiedIds), forKey: "notified_ids")

        // 推送文案优先用已翻译的标题；没有就当场翻：
        //   有大模型 Key → 走 LLM（后台也能用）；否则用离线词典兜底。
        func deliver(_ zhTitle: String) {
            let content = UNMutableNotificationContent()
            if fresh.count == 1 {
                let t = zhTitle.isEmpty ? Self.zhFallback(first) : zhTitle
                content.title = "【\(first.site.label)】" + t
                var body = first.summary
                if body.isEmpty { body = first.brief.first ?? "" }
                if body.isEmpty { body = first.title }
                if let name = first.author.isEmpty ? nil : first.author {
                    body = name + "：" + body
                }
                content.body = body.count > 96 ? String(body.prefix(96)) + "…" : body
                content.subtitle = TimeFmt.feedText(first.ts) + " 北京时间"
            } else {
                content.title = "彭博与路透新闻 · \(fresh.count) 条新稿"
                content.body = fresh.prefix(3)
                    .map { $0.titleZh.isEmpty ? Self.zhFallback($0) : $0.titleZh }
                    .joined(separator: "；")
                content.subtitle = "最新 " + TimeFmt.feedText(first.ts) + " 北京时间"
            }
            content.sound = .default
            if #available(iOS 15.0, *) {
                content.interruptionLevel = .timeSensitive
                content.relevanceScore = 1.0
            }
            content.threadIdentifier = first.site.rawValue
            content.categoryIdentifier = "BPC_NEWS"
            content.userInfo = ["itemId": first.id]
            // 用 1 秒触发器：比 nil 更稳（nil 在部分系统版本上会被合并或静默丢弃）
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let req = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
        }

        if !first.titleZh.isEmpty {
            deliver(first.titleZh)
        } else if Settings.zhMode == "llm" && !Settings.llmKey.isEmpty {
            Translator.translateTitle(first.title) { zh in
                DispatchQueue.main.async { deliver(zh) }
            }
        } else {
            deliver("")
        }
    }

    /// 没有系统/大模型翻译时的兜底：离线词典
    static func zhFallback(_ item: FeedItem) -> String {
        let zh = Dict.translate(item.title)
        // 如果几乎没替换成功（中文字符很少），干脆给原文，避免误导
        let hanzi = zh.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
        return hanzi >= 6 ? zh : item.title
    }

    // MARK: - 工具

    static func cleanTitle(_ t: String) -> String {
        var s = t.trimmed
        for suffix in [" - Bloomberg.com", " - Bloomberg", " - Reuters", " | Reuters",
                       " - Reuters.com", " | Bloomberg"] {
            if s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
        }
        return s.trimmed
    }

    var pendingCount: Int {
        items.filter { !$0.fetched }.count
    }
}
