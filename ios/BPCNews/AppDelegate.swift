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
        // 一次性迁移：老版本可能把 keep_alive 写成 false，这里强制开启一次
        if UserDefaults.standard.object(forKey: "keep_alive_user_set") == nil {
            UserDefaults.standard.set(true, forKey: "keep_alive")
        }
        registerNotificationCategory()
        requestNotificationPermission()
        FeedStore.shared.bootstrap()
        FeedStore.shared.startMonitoring()
        if Settings.keepAlive { SilentKeeper.start() }
        return true
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        SilentKeeper.stop()
        FeedStore.shared.startMonitoring()
        FeedStore.shared.refresh()
    }

    /// 通知上的快捷动作：打开 / 收藏
    private func registerNotificationCategory() {
        let open = UNNotificationAction(identifier: "BPC_OPEN", title: "打开", options: [.foreground])
        let save = UNNotificationAction(identifier: "BPC_SAVE", title: "收藏", options: [])
        let cat = UNNotificationCategory(identifier: "BPC_NEWS",
                                         actions: [open, save],
                                         intentIdentifiers: [],
                                         options: [])
        UNUserNotificationCenter.current().setNotificationCategories([cat])
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, err in
            UserDefaults.standard.set(ok, forKey: "notif_authorized")
            if let err = err { print("[notif] auth error: \(err.localizedDescription)") }
            // 被拒时给出可见提示（设置页也会显示状态）
            print("[notif] authorized=\(ok)")
        }
    }

    /// 发送一条测试通知（设置页按钮调用，用来验证权限与展示）
    static func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "【测试】通知链路正常"
        content.subtitle = TimeFmt.feedText(Int(Date().timeIntervalSince1970)) + " 北京时间"
        content.body = "如果你看到这条，说明本地通知与前台展示都工作正常。"
        content.sound = .default
        content.categoryIdentifier = "BPC_NEWS"
        if #available(iOS 15.0, *) { content.interruptionLevel = .timeSensitive }
        let req = UNNotificationRequest(identifier: "bpc.test.\(UUID().uuidString)",
                                        content: content,
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2,
                                                                                  repeats: false))
        UNUserNotificationCenter.current().add(req) { err in
            if let err = err { print("[notif] test add error: \(err.localizedDescription)") }
        }
    }

    // MARK: - 后台刷新（系统调度，用来「自动发现」）

    func applicationDidEnterBackground(_ application: UIApplication) {
        if Settings.keepAlive {
            // 保活模式：音频后台模式让 App 继续运行，定时器不停
            SilentKeeper.start()
        } else {
            FeedStore.shared.stopMonitoring()   // 普通模式：交给系统后台任务
        }

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
        if response.actionIdentifier == "BPC_SAVE",
           let itemId = info["itemId"] as? String, !itemId.isEmpty {
            Library.shared.toggleSaved(itemId)
            completionHandler()
            return
        }
        if let itemId = info["itemId"] as? String, !itemId.isEmpty {
            DeepLink.shared.pendingItemId = itemId
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .bpcOpenItem, object: itemId)
            }
        }
        completionHandler()
    }
}
