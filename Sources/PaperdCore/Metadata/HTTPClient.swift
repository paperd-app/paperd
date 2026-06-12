import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 外部API・ワーカーHTTPの共通クライアント抽象。テストではスタブ実装を注入する。
public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct HTTPRequest: Sendable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case head = "HEAD"
    }

    public var method: Method
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: Method = .get, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }

    /// 429時のRetry-After（秒）（→ docs/04 9節）
    public var retryAfterSeconds: Double? {
        headers.first { $0.key.lowercased() == "retry-after" }.flatMap { Double($0.value) }
    }
}

public enum HTTPError: Error, CustomStringConvertible {
    case statusCode(Int, body: Data, retryAfter: Double?)
    case invalidResponse

    public var description: String {
        switch self {
        case .statusCode(let code, _, _): return "HTTP \(code)"
        case .invalidResponse: return "Invalid HTTP response"
        }
    }

    /// 一時的エラー（5xx / 429）はバックオフリトライ対象（→ docs/04 7節）
    public var isTransient: Bool {
        if case .statusCode(let code, _, _) = self {
            return code == 429 || (500..<600).contains(code)
        }
        return false
    }
}

public struct URLSessionHTTPClient: HTTPClient {
    let session: URLSession

    /// 既定セッションはタイムアウトを長めに取る。
    /// ワーカーの/embedはモデルのコールドロード（初回はダウンロード含む）で60秒を超えうるため
    public init(session: URLSession = URLSessionHTTPClient.defaultSession) {
        self.session = session
    }

    public static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }()

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String { headers[k] = v }
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}
