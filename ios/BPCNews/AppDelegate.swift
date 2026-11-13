import UIKit
import UserNotifications
import BackgroundTasks

extension Notification.Name {
    static let bpcOpenItem = Notification.Name("bpcOpenItem")
}

final class DeepLink {
    static let shared = DeepLink()
    var pendingItemId: String?
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    static var bgTaskID: String {
        (Bundle.main.bundleIdentifier ?? "com.yourname.bpcnews") + ".refresh"
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: AppDelegate.bgTaskID,
                                            using: nil) { task in
            self.handleBackground(task)
        }
        requestNotificationPermission()
        FeedStore.shared.bootstrap()
        return true
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - 后台刷新（系统调度，用来「自动发现」）

    func applicationDidEnterBackground(_ application: UIApplication) {
        scheduleBackground()
    }

    func scheduleBackground() {
        let req = BGAppRefreshTaskRequest(identifier: AppDelegate.bgTaskID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    private func handleBackground(_ task: BGTask) {
        scheduleBackground()
        let refresh = task as? BGAppRefreshTask
        let work = Task {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                FeedStore.shared.refresh(notify: true) { cont.resume() }
            }
            refresh?.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    // MARK: - 通知回调

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let itemId = info["itemId"] as? String, !itemId.isEmpty {
            DeepLink.shared.pendingItemId = itemId
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .bpcOpenItem, object: itemId)
            }
        }
        completionHandler()
    }
}
