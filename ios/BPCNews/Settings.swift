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

    // 抓取
    static var autoFetch: Bool {
        UserDefaults.standard.object(forKey: "auto_fetch") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "auto_fetch")
    }

    // 翻译（三种模式：dict 离线词典 / llm 大模型 / off 关闭）
    static var zhMode: String {
        let v = UserDefaults.standard.string(forKey: "zh_mode") ?? ""
        return v.isEmpty ? "dict" : v       // 默认：离线词典，直接显示中文
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
