import Foundation

/// 列表项（服务端 /v1/feed 返回）
struct FeedItem: Codable, Identifiable, Equatable {
    let id: String
    let site: String
    let url: String
    let title: String
    let titleZh: String
    let brief: [String]
    let ts: Int

    enum CodingKeys: String, CodingKey {
        case id, site, url, title, brief, ts
        case titleZh = "title_zh"
    }
}

/// 正文块
struct Block: Codable, Equatable {
    let type: String      // p / h2 / quote / li / img / hr
    let text: String
    let zh: String?
    let src: String?
}

/// 文章（服务端 /v1/article/{id} 返回）
struct Article: Codable, Identifiable, Equatable {
    let id: String
    let site: String
    let url: String
    let title: String
    let titleZh: String
    let brief: [String]
    let audio: String?
    let blocks: [Block]
    let publishedTs: Int?

    enum CodingKeys: String, CodingKey {
        case id, site, url, title, brief, audio, blocks
        case titleZh = "title_zh"
        case publishedTs = "published_ts"
    }
}
