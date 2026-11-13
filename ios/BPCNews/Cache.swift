import Foundation

/// 本地缓存：断网也能看已读文章；列表缓存让冷启动秒开
enum Cache {
    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }

    static var feedFile: URL { dir.appendingPathComponent("feed.json") }

    static func saveFeed(_ items: [FeedItem]) {
        guard let d = try? JSONEncoder().encode(items) else { return }
        try? d.write(to: feedFile, options: .atomic)
    }

    static func loadFeed() -> [FeedItem] {
        guard let d = try? Data(contentsOf: feedFile) else { return [] }
        return (try? JSONDecoder().decode([FeedItem].self, from: d)) ?? []
    }

    static func articleFile(_ id: String) -> URL {
        dir.appendingPathComponent("art_\(id).json")
    }

    static func saveArticle(_ a: Article) {
        guard let d = try? JSONEncoder().encode(a) else { return }
        try? d.write(to: articleFile(a.id), options: .atomic)
    }

    static func loadArticle(_ id: String) -> Article? {
        guard let d = try? Data(contentsOf: articleFile(id)) else { return nil }
        return try? JSONDecoder().decode(Article.self, from: d)
    }
}
