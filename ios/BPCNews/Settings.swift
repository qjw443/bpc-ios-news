import Foundation
import WebKit

/// 本地设置（全部存在 UserDefaults，App 自包含，不连自建服务器）
enum Settings {

    // 来源
    static var enabledSites: [String] {
        var out: [String] = []
        if UserDefaults.standard.object(forKey: "src_bloomberg") == nil ||
            UserDefaults.standard.bool(forKey: "src_bloomberg") {
            out.append("bloomberg")
        }
        if UserDefaults.standard.object(forKey: "src_reuters") == nil ||
            UserDefaults.standard.bool(forKey: "src_reuters") {
            out.append("reuters")
        }
        return out.isEmpty ? ["bloomberg", "reuters"] : out
    }

    // 发现
    /// 只收多少小时内的稿子（彭博 sitemap 会带出 60+ 小时的旧闻，必须截断）
    static var freshHours: Int {
        let v = UserDefaults.standard.integer(forKey: "fresh_hours")
        return v == 0 ? 24 : v
    }
    /// 推送只看多少分钟内的稿子（避免一次推一堆历史）
    static let pushWindowMinutes = 120

    static var autoFetch: Bool {
        UserDefaults.standard.object(forKey: "auto_fetch") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "auto_fetch")
    }

    // 翻译（四种模式：sys 系统端上 / dict 离线词典 / llm 大模型 / off 关闭）
    static var zhMode: String {
        let v = UserDefaults.standard.string(forKey: "zh_mode") ?? ""
        if !v.isEmpty { return v }
        // 默认：能用系统端上翻译就用它（真翻译、离线、无 Key）
        if #available(iOS 18.0, *) { return "sys" }
        return "dict"
    }
    static var llmKey: String { UserDefaults.standard.string(forKey: "llm_key") ?? "" }
    static var llmModel: String {
        let v = UserDefaults.standard.string(forKey: "llm_model") ?? ""
        return v.isEmpty ? "deepseek-chat" : v
    }
    static var llmURL: String {
        let v = UserDefaults.standard.string(forKey: "llm_url") ?? ""
        return v.isEmpty ? "https://api.deepseek.com/chat/completions" : v
    }
    static var translateOnOpen: Bool { UserDefaults.standard.bool(forKey: "translate_on_open") }

    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }
}
