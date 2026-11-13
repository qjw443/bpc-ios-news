import Foundation

/// 全局设置：全部落在 UserDefaults，方便「设置页」直接改、也方便自签重装后保留（同一 Bundle ID 时）
enum Settings {
    static let defaultBase = "https://news.example.com"

    static var base: String {
        let v = UserDefaults.standard.string(forKey: "api_base") ?? defaultBase
        return v.isEmpty ? defaultBase : v
    }

    static var token: String {
        UserDefaults.standard.string(forKey: "api_token") ?? ""
    }

    /// 自签：开发描述文件 -> sandbox；发布证书 -> production
    static var apnsEnv: String {
        if let v = UserDefaults.standard.string(forKey: "apns_env"), !v.isEmpty {
            return v
        }
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    static var quietFrom: Int { UserDefaults.standard.integer(forKey: "quiet_from") }
    static var quietTo: Int { UserDefaults.standard.integer(forKey: "quiet_to") }

    static func enabledSites() -> [String] {
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
}
