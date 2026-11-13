import Foundation
import UIKit
import UserNotifications

/// APNs 注册与上报。自签证书若无 Push 权限，这里会优雅失败并提示降级。
final class PushManager: ObservableObject {
    static let shared = PushManager()

    @Published var status: String = "未注册"
    @Published var token: String = UserDefaults.standard.string(forKey: "apns_token") ?? ""

    func bootstrap() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else {
                self.setStatus("通知未授权")
                return
            }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    func didRegister(_ deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: "apns_token")
        DispatchQueue.main.async {
            self.token = hex
            self.status = "已注册 " + String(hex.prefix(10)) + "…"
        }
        Task { await self.upload(hex) }
    }

    func didFail(_ error: Error) {
        UserDefaults.standard.set(false, forKey: "push_ok")
        setStatus("推送不可用（证书不含 Push 权限，已降级为轮询）")
    }

    func upload(_ hex: String) async {
        let payload: [String: Any] = [
            "token": hex,
            "env": Settings.apnsEnv,
            "sites": Settings.enabledSites(),
            "realtime": true,
            "quiet_from": Settings.quietFrom,
            "quiet_to": Settings.quietTo
        ]
        do {
            _ = try await APIClient.post("/v1/device", json: payload)
            UserDefaults.standard.set(true, forKey: "push_ok")
            setStatus("服务端已登记")
        } catch {
            UserDefaults.standard.set(false, forKey: "push_ok")
            setStatus("上报失败：" + error.localizedDescription)
        }
    }

    private func setStatus(_ s: String) {
        DispatchQueue.main.async { self.status = s }
    }
}
