import Foundation

enum APIError: LocalizedError {
    case badURL
    case unauthorized
    case http(Int)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "服务器地址无效"
        case .unauthorized: return "API Token 不正确"
        case .http(let c): return "HTTP \(c)"
        case .decode(let s): return "数据解析失败：\(s)"
        }
    }
}

enum APIClient {
    static var session: URLSession {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = true
        return URLSession(configuration: c)
    }

    static func makeRequest(_ path: String, method: String = "GET",
                            json: [String: Any]? = nil) throws -> URLRequest {
        var b = Settings.base
        while b.hasSuffix("/") { b.removeLast() }
        guard let url = URL(string: b + path) else { throw APIError.badURL }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer " + Settings.token, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json = json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return r
    }

    static func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let (data, resp) = try await session.data(for: try makeRequest(path))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw APIError.unauthorized }
        guard code == 200 else { throw APIError.http(code) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decode("\(error)")
        }
    }

    @discardableResult
    static func post(_ path: String, json: [String: Any]) async throws -> Data {
        let (data, resp) = try await session.data(
            for: try makeRequest(path, method: "POST", json: json))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw APIError.unauthorized }
        guard code == 200 else { throw APIError.http(code) }
        return data
    }
}
