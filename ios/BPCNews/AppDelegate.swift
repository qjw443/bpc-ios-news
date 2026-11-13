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
    static var bgProcessingID: String {
        (Bundle.main.bundleIdentifier ?? "com.yourname.bpcnews") + ".processing"
    }

    private var bgAssertion: UIBackgroundTaskIdentifier = .invalid

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: AppDelegate.bgTaskID,
                                            using: nil) { task in
            self.handleBackground(task)
        }
        // 处理型任务：系统会给更长执行时间，用于把一轮发现跑完
        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: AppDelegate.bgProcessingID,
                                            using: nil) { task in
            self.handleProcessing(task)
        }
        requestNotificationPermission()
        FeedStore.shared.bootstrap()
        FeedStore.shared.startMonitoring()
        return true
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        FeedStore.shared.startMonitoring()
        FeedStore.shared.refresh()
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - 后台刷新（系统调度，用来「自动发现」）

    func applicationDidEnterBackground(_ application: UIApplication) {
        FeedStore.shared.stopMonitoring()   // 前台定时器停掉，交给系统后台任务

        // 退后台时抢跑一轮：申请 background assertion，争取在挂起前把发现跑完
        bgAssertion = application.beginBackgroundTask(withName: "bpc.refresh.onbackground") {
            if self.bgAssertion != .invalid {
                application.endBackgroundTask(self.bgAssertion)
                self.bgAssertion = .invalid
            }
        }
        FeedStore.shared.refresh(notify: true) { [weak self, weak application] in
            guard let self = self, let app = application, self.bgAssertion != .invalid else { return }
            app.endBackgroundTask(self.bgAssertion)
            self.bgAssertion = .invalid
        }

        scheduleBackground()
    }

    func scheduleBackground() {
        // ① App 刷新任务：尽早排（系统仍会按自己的节奏调度）
        let refresh = BGAppRefreshTaskRequest(identifier: AppDelegate.bgTaskID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        try? BGTaskScheduler.shared.submit(refresh)

        // ② 处理任务：需要联网、不强制充电，给更长的执行窗口
        let processing = BGProcessingTaskRequest(identifier: AppDelegate.bgProcessingID)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(processing)
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

    private func handleProcessing(_ task: BGTask) {
        scheduleBackground()
        task.expirationHandler = { FeedStore.shared.stopMonitoring() }
        let work = Task {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                FeedStore.shared.refresh(notify: true) { cont.resume() }
            }
            task.setTaskCompleted(success: true)
        }
        _ = work
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
