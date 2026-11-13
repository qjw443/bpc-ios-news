import Foundation

/// 时间显示：所有时间统一换算成**北京时间（Asia/Shanghai, UTC+8）**。
/// 源站用的都是 UTC / GMT，直接显示会差 8 小时，所以这里集中处理，避免各处再写时区。
enum TimeFmt {
    static let beijing = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!

    private static let hm: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = beijing
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let mdhm: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = beijing
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private static let full: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = beijing
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = beijing
        return c
    }()

    /// 列表用：今天 → "21:14"；昨天 → "昨天 21:14"；更早 → "11-12 21:14"
    static func feedText(_ ts: Int) -> String {
        guard ts > 0 else { return "" }
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        if cal.isDateInToday(d) { return hm.string(from: d) }
        if cal.isDateInYesterday(d) { return "昨天 " + hm.string(from: d) }
        return mdhm.string(from: d)
    }

    /// 阅读页用：完整北京时间
    static func fullText(_ ts: Int) -> String {
        guard ts > 0 else { return "" }
        return full.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// 上一篇/多久前（相对时间，用北京时间无关）
    static func ago(_ ts: Int) -> String {
        guard ts > 0 else { return "" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(ts)),
                                 relativeTo: Date())
    }
}
