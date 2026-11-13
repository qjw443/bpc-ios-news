import Foundation
import UserNotifications

/// 列表数据源：前台轮询 / 后台刷新 / 下拉刷新 都走这里
final class FeedStore: ObservableObject {
    static let shared = FeedStore()

    @Published var items: [FeedItem] = []
    @Published var lastError: String = ""
    @Published var loading: Bool = false

    private let lastTsKey = "last_ts"

    private var lastTs: Int {
        get { UserDefaults.standard.integer(forKey: lastTsKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastTsKey) }
    }

    func loadCache() {
        let cached = Cache.loadFeed()
        if !cached.isEmpty {
            DispatchQueue.main.async {
                if self.items.isEmpty { self.items = cached }
            }
        }
    }

    /// full=true 时拉全量（首启/下拉刷新）；notify=true 时对新增发本地通知（后台刷新用）
    func refresh(full: Bool = false, notify: Bool = false) async {
        await MainActor.run { self.loading = true }
        let after = full ? 0 : lastTs
        do {
            let fresh: [FeedItem] = try await APIClient.get(
                "/v1/feed?limit=60&after=\(after)", as: [FeedItem].self)

            await MainActor.run {
                var map: [String: FeedItem] = [:]
                for it in self.items { map[it.id] = it }
                for it in fresh { map[it.id] = it }
                self.items = map.values.sorted { $0.ts > $1.ts }
                self.lastError = ""
                self.loading = false
                Cache.saveFeed(self.items)
            }

            if !fresh.isEmpty {
                let maxTs = fresh.map { $0.ts }.max() ?? 0
                if maxTs > lastTs { lastTs = maxTs }
                if notify { Self.postLocalNotification(fresh) }
            }
        } catch {
            await MainActor.run {
                self.lastError = error.localizedDescription
                self.loading = false
            }
        }
    }

    /// 无 APNs 权限时的降级通道：本地通知（前台/后台刷新触发）
    static func postLocalNotification(_ fresh: [FeedItem]) {
        guard let first = fresh.first else { return }
        let content = UNMutableNotificationContent()
        if fresh.count == 1 {
            content.title = first.titleZh
            content.body = first.brief.joined(separator: "；")
        } else {
            content.title = "财经速递 · \(fresh.count) 条新消息"
            content.body = first.titleZh
        }
        content.sound = .default
        content.userInfo = ["aid": first.id]
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
