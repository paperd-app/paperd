import Foundation

/// stdio JSON-RPC 2.0の最小実装（→ docs/07 1節）。
/// MCP仕様のうちtoolsのみ使用するため、SDKに依存せず自前実装とする
/// （公式Swift SDK停滞リスクへのヘッジ → docs/10 R2）。
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "未知のJSON値")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n):
            if n == n.rounded() && abs(n) < 1e15 {
                try container.encode(Int64(n))
            } else {
                try container.encode(n)
            }
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        if case .number(let n) = self { return Int(n) }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

public struct JSONRPCRequest: Codable, Equatable, Sendable {
    public var jsonrpc: String
    public var id: JSONValue?
    public var method: String
    public var params: JSONValue?

    public init(id: JSONValue?, method: String, params: JSONValue? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }

    public var isNotification: Bool { id == nil }
}

public struct JSONRPCResponse: Codable, Equatable, Sendable {
    public var jsonrpc: String
    public var id: JSONValue?
    public var result: JSONValue?
    public var error: JSONRPCError?

    public init(id: JSONValue?, result: JSONValue) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: JSONValue?, error: JSONRPCError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }
}

public struct JSONRPCError: Codable, Equatable, Sendable {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public static let parseError = JSONRPCError(code: -32700, message: "Parse error")
    public static func methodNotFound(_ method: String) -> JSONRPCError {
        JSONRPCError(code: -32601, message: "Method not found: \(method)")
    }
    public static func invalidParams(_ message: String) -> JSONRPCError {
        JSONRPCError(code: -32602, message: message)
    }
}
