import Foundation

/// 运行诊断：真机上出问题时，用户一键复制这段报告，我就能定位是哪一层失效。
struct DiagEntry: Identifiable, Codable {
    let id: String
    let at: Int
    let site: String
    let url: String
    let finalURL: String
    let via: String
    let blocks: Int
    let walls: [String]
    let ms: Int
    let ok: Bool
    let note: String
}

final class Diagnostics {
    static let shared = Diagnostics()

    private(set) var entries: [DiagEntry] = []
    private let key = "diag_entries"

    private init() { load() }

    func record(site: String, url: String, finalURL: String, via: String,
                blocks: Int, walls: [String], ms: Int, ok: Bool, note: String = "") {
        let e = DiagEntry(id: UUID().uuidString, at: Int(Date().timeIntervalSince1970),
                          site: site, url: url, finalURL: finalURL, via: via,
                          blocks: blocks, walls: walls, ms: ms, ok: ok, note: note)
        entries.insert(e, at: 0)
        if entries.count > 40 { entries = Array(entries.prefix(40)) }
        persist()
    }

    var report: String {
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm:ss"
        var lines = ["=== BPC 诊断报告 ===",
                     "app: \(Settings.appVersion)  rules: \(PaywallEngine.shared.compiledCount)/2"]
        for e in entries.prefix(12) {
            let t = df.string(from: Date(timeIntervalSince1970: TimeInterval(e.at)))
            lines.append("[\(t)] \(e.site) \(e.ok ? "OK" : "FAIL") via=\(e.via) blocks=\(e.blocks) \(e.ms)ms")
            if !e.walls.isEmpty { lines.append("    walls: \(e.walls.joined(separator: " | "))") }
            if !e.note.isEmpty { lines.append("    note: \(e.note)") }
            lines.append("    url: \(e.url)")
            if e.finalURL != e.url { lines.append("    final: \(e.finalURL)") }
        }
        return lines.joined(separator: "\n")
    }

    func clear() {
        entries = []
        persist()
    }

    private func persist() {
        guard let d = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(d, forKey: key)
    }

    private func load() {
        guard let d = UserDefaults.standard.data(forKey: key),
              let arr = try? JSONDecoder().decode([DiagEntry].self, from: d) else { return }
        entries = arr
    }
}
