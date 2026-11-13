import UIKit
import UserNotifications
import BackgroundTasks

extension Notification.Name {
    static let bpcOpenArticle = Notification.Name("bpcOpenArticle")
}

/// 冷启动时点击推送的场景：先把 aid 存下来，等界面出来再跳转
final class DeepLink {
    static let shared = DeepLink()
    var pendingArticleId: String?
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    static var bgTaskID: String {
        (Bundle.main.bundleIdentifier ?? "com.yourname.bpcnews") + ".refresh"
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        // 后台刷新任务必须在 didFinishLaunching 里注册，否则永远调度不到
        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: AppDelegate.bgTaskID,
                                            using: nil) { task in
            self.handleBackgroundRefresh(task)
        }

        PushManager.shared.bootstrap()
        return true
    }

    // MARK: - APNs

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushManager.shared.didRegister(deviceToken)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushManager.shared.didFail(error)
    }

    // MARK: - 后台刷新

    func applicationDidEnterBackground(_ application: UIApplication) {
        scheduleBackgroundRefresh()
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: AppDelegate.bgTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do { try BGTaskScheduler.shared.submit(request) } catch {
            print("BG submit failed: \(error)")
        }
    }

    private func handleBackgroundRefresh(_ task: BGTask) {
        scheduleBackgroundRefresh()
        let guardTask = task as? BGAppRefreshTask
        let work = Task {
            await FeedStore.shared.refresh(notify: true)
            guardTask?.setTaskCompleted(success: true)
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
        if let aid = info["aid"] as? String, !aid.isEmpty, aid != "test" {
            DeepLink.shared.pendingArticleId = aid
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .bpcOpenArticle, object: aid)
            }
        }
        completionHandler()
    }
}
