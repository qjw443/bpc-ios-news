import Foundation

// MARK: - 站点

enum Site: String, Codable, CaseIterable {
    case bloomberg
    case reuters

    var label: String { self == .bloomberg ? "彭博" : "路透" }
    var tag: String { self == .bloomberg ? "BLOOMBERG" : "REUTERS" }

    var domains: [String] {
        self == .bloomberg ? ["bloomberg.com", "bwbx.io"] : ["reuters.com"]
    }
}

// MARK: - 模型

struct FeedItem: Codable, Identifiable, Equatable {
    let id: String            // = url 的 hash
    let site: Site
    let title: String
    var url: String           // Google 跳转解析后会被就地改写为真实文章地址
    let ts: Int               // unix 秒
    var titleZh: String = ""
    var brief: [String] = []
    var fetched: Bool = false // 正文是否已抓到本地
}

struct Block: Codable, Equatable {
    let type: String          // p / h2 / quote / li / img / hr
    let text: String
    var zh: String = ""
    let src: String?
}

struct Article: Codable, Identifiable, Equatable {
    var id: String
    var site: Site
    var url: String
    var title: String
    var titleZh: String = ""
    var brief: [String] = []
    var audio: String?
    var blocks: [Block] = []
    var fetchedAt: Int = 0
    var fromArchive: Bool = false
    var via: String = ""       // 命中的提取策略（next_data / dom_artbodytext / testid_paragraph / archive …）
    var walls: [String] = []   // 提取时仍检测到的付费墙节点（诊断用）
}

// MARK: - 本地库（纯 JSON 落盘，不依赖任何服务端）

final class Library {
    static let shared = Library()

    private(set) var items: [FeedItem] = []           // 按 ts 倒序
    private(set) var articles: [String: Article] = [:]
    private let queue = DispatchQueue(label: "bpc.library")

    private var dir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask)[0]
        if !FileManager.default.fileExists(atPath: u.path) {
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        }
        return u
    }
    private var feedURL: URL { dir.appendingPathComponent("feed.json") }
    private var artDir: URL {
        let u = dir.appendingPathComponent("articles")
        if !FileManager.default.fileExists(atPath: u.path) {
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        }
        return u
    }

    // MARK: 读写

    func load() {
        if let d = try? Data(contentsOf: feedURL),
           let arr = try? JSONDecoder().decode([FeedItem].self, from: d) {
            items = arr
        }
        articles.removeAll()
    }

    private func persistFeed() {
        guard let d = try? JSONEncoder().encode(items) else { return }
        try? d.write(to: feedURL, options: .atomic)
    }

    /// 合并发现结果，返回「新入库」的条目
    @discardableResult
    func merge(_ found: [FeedItem], limit: Int = 300) -> [FeedItem] {
        var seen = Set(items.map { $0.id })
        var fresh: [FeedItem] = []
        for it in found where !seen.contains(it.id) {
            items.append(it)
            seen.insert(it.id)
            fresh.append(it)
        }
        items.sort { $0.ts > $1.ts }
        if items.count > limit { items = Array(items.prefix(limit)) }
        persistFeed()
        return fresh
    }

    func markFetched(_ id: String, article: Article) {
        if let i = items.firstIndex(where: { $0.id == id }) {
            items[i].fetched = true
            if !article.titleZh.isEmpty { items[i].titleZh = article.titleZh }
            if !article.brief.isEmpty { items[i].brief = article.brief }
            persistFeed()
        }
        articles[id] = article
        queue.async {
            guard let d = try? JSONEncoder().encode(article) else { return }
            try? d.write(to: self.artDir.appendingPathComponent(id + ".json"), options: .atomic)
        }
    }

    func article(for id: String) -> Article? {
        if let a = articles[id] { return a }
        let u = artDir.appendingPathComponent(id + ".json")
        guard let d = try? Data(contentsOf: u),
              let a = try? JSONDecoder().decode(Article.self, from: d) else { return nil }
        articles[id] = a
        return a
    }

    func item(for id: String) -> FeedItem? {
        items.first { $0.id == id }
    }

    /// Google News 跳转解析成功后，把条目 URL 就地换成真实地址
    func updateURL(_ id: String, to url: String) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].url != url else { return }
        items[i].url = url
        persistFeed()
    }

    /// 标题中文化（供列表页翻译回填）
    func setTitleZh(_ id: String, _ zh: String) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].titleZh != zh else { return }
        items[i].titleZh = zh
        persistFeed()
    }

    func removeAll() {
        items = []
        articles = [:]
        try? FileManager.default.removeItem(at: feedURL)
        try? FileManager.default.removeItem(at: artDir)
        try? FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)
    }
}

// MARK: - 小工具

enum Hash {
    static func short(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(h, radix: 16)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
