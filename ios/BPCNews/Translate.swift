import Foundation

/// App 内翻译：走任意 OpenAI 兼容接口（默认 DeepSeek），段落 1:1 对齐。
/// 不填 key 就不显示翻译入口，纯本地阅读照常可用。
enum Translator {

    private static let glossary = "Fed=美联储；ECB=欧洲央行；BOJ=日本央行；BOE=英国央行；PBOC=中国人民银行；"
        + "SEC=美国证监会；M&A=并购；IPO=首次公开募股；earnings=财报；guidance=业绩指引；"
        + "tariff=关税；yield=收益率；basis point=基点；inflation=通胀；CPI=消费者物价指数"

    private static let system = "你是资深财经新闻译者，把英文新闻译成简体中文。"
        + "严格按输入 JSON 数组顺序输出等长数组、不合并不增删；"
        + "人名/机构/产品/股票代码/数字/百分比原样保留；术语按术语表；"
        + "不添加解释、不使用省略号、不要 Markdown、只输出 JSON 数组。"

    enum TranslateError: LocalizedError {
        case noKey
        case badResponse(String)
        case align(Int, Int)

        var errorDescription: String? {
            switch self {
            case .noKey: return "未配置翻译 Key（设置里填 LLM Key）"
            case .badResponse(let s): return "翻译接口返回异常：\(s)"
            case .align(let a, let b): return "段落对齐失败（\(a) vs \(b)）"
            }
        }
    }

    static func translate(_ article: Article, completion: @escaping (Result<Article, Error>) -> Void) {
        // ① 关闭
        if Settings.zhMode == "off" {
            completion(.success(article))
            return
        }
        // ② 离线词典（默认；无需网络、无需 Key）
        if Settings.zhMode == "dict" || Settings.llmKey.isEmpty {
            completion(.success(dictionary(article)))
            return
        }
        // ③ LLM 整句翻译
        guard !Settings.llmKey.isEmpty else {
            completion(.failure(TranslateError.noKey))
            return
        }
        llmTranslate(article, completion: completion)
    }

    /// 离线词典：术语级替换，纯本地、瞬时完成
    static func dictionary(_ article: Article) -> Article {
        var art = article
        for i in art.blocks.indices {
            let b = art.blocks[i]
            if b.type == "img" || b.type == "hr" { continue }
            art.blocks[i].zh = Dict.translate(b.text)
        }
        art.titleZh = Dict.translate(art.title)
        if art.brief.isEmpty {
            art.brief = art.blocks.filter { $0.type == "p" }
                .prefix(3)
                .map { String(Dict.translate($0.text).prefix(46)) }
        }
        return art
    }

    private static func llmTranslate(_ article: Article,
                                     completion: @escaping (Result<Article, Error>) -> Void) {
        var art = article
        let todo = art.blocks.enumerated().filter { _, b in
            b.zh.isEmpty && (b.type == "p" || b.type == "h2" || b.type == "quote" || b.type == "li")
        }
        guard !todo.isEmpty else {
            completion(.success(art))
            return
        }

        // 分批，单批 ≤ 1800 字符，保证段落 1:1
        var batches: [[(Int, Block)]] = []
        var cur: [(Int, Block)] = []
        var size = 0
        for (i, b) in todo {
            if size + b.text.count > 1800 && !cur.isEmpty {
                batches.append(cur)
                cur = []
                size = 0
            }
            cur.append((i, b))
            size += b.text.count
        }
        if !cur.isEmpty { batches.append(cur) }

        func run(_ index: Int) {
            guard index < batches.count else {
                completion(.success(art))
                return
            }
            let batch = batches[index]
            let texts = batch.map { $0.1.text }
            let prompt = "术语表：\(glossary)\n\n把下面 JSON 数组逐段译成中文，输出等长 JSON 数组（只输出数组）：\n"
                + (jsonString(texts) ?? "[]")

            chat(system: system, user: prompt) { result in
                switch result {
                case .failure(let e):
                    completion(.failure(e))
                case .success(let raw):
                    guard let arr = parseArray(raw), arr.count == batch.count else {
                        completion(.failure(TranslateError.align(parseArray(raw)?.count ?? -1, batch.count)))
                        return
                    }
                    for (k, pair) in batch.enumerated() {
                        art.blocks[pair.0].zh = arr[k].trimmed
                    }
                    run(index + 1)
                }
            }
        }
        run(0)
    }

    // MARK: - 单条标题/要点（可选）

    static func translateTitle(_ title: String, completion: @escaping (String) -> Void) {
        guard !Settings.llmKey.isEmpty else { completion(""); return }
        chat(system: "只输出中文标题，不超过 40 字，不要引号不要解释。",
             user: "术语表：\(glossary)\n\n标题：\(title)") { r in
            switch r {
            case .success(let s): completion(s.trimmed.replacingOccurrences(of: "\"", with: ""))
            case .failure: completion("")
            }
        }
    }

    // MARK: - HTTP

    private static func chat(system: String, user: String,
                             completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: Settings.llmURL) else {
            completion(.failure(TranslateError.badResponse("URL 无效")))
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 90)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(Settings.llmKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": Settings.llmModel,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(TranslateError.badResponse("请求体序列化失败")))
            return
        }
        req.httpBody = data

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                completion(.failure(err))
                return
            }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                completion(.failure(TranslateError.badResponse("HTTP \(code)")))
                return
            }
            completion(.success(content))
        }.resume()
    }

    // MARK: - JSON 辅助

    private static func jsonString(_ arr: [String]) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed]),
              let s = String(data: d, encoding: .utf8) else { return nil }
        return s
    }

    private static func parseArray(_ raw: String) -> [String]? {
        var s = raw.trimmed
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmed
        }
        guard let start = s.firstIndex(of: "["), let end = s.lastIndex(of: "]") else { return nil }
        let sub = String(s[start...end])
        guard let d = sub.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String]
    }
}
