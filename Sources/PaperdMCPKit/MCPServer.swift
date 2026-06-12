import Foundation

/// MCPサーバ本体: initialize / tools/list / tools/call のみを扱う薄い層（→ docs/07）。
/// stdioの改行区切りJSONメッセージを1行ずつ処理する。
public struct MCPServer: Sendable {
    public static let protocolVersion = "2024-11-05"
    public static let serverName = "paperd"
    public static let serverVersion = "0.1.0"

    let tools: PaperdTools

    public init(tools: PaperdTools) {
        self.tools = tools
    }

    /// 1行のJSON-RPCメッセージを処理してレスポンス（通知の場合nil）を返す
    public func handle(line: String) async -> String? {
        guard let data = line.data(using: .utf8),
              let request = try? JSONDecoder().decode(JSONRPCRequest.self, from: data)
        else {
            return Self.serialize(JSONRPCResponse(id: .null, error: .parseError))
        }
        guard let response = await handle(request: request) else { return nil }
        return Self.serialize(response)
    }

    public func handle(request: JSONRPCRequest) async -> JSONRPCResponse? {
        switch request.method {
        case "initialize":
            return JSONRPCResponse(id: request.id, result: .object([
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object([
                    "name": .string(Self.serverName),
                    "version": .string(Self.serverVersion),
                ]),
            ]))

        case "notifications/initialized", "initialized":
            return nil

        case "ping":
            return JSONRPCResponse(id: request.id, result: .object([:]))

        case "tools/list":
            return JSONRPCResponse(id: request.id, result: .object([
                "tools": .array(PaperdTools.definitions),
            ]))

        case "tools/call":
            guard let name = request.params?["name"]?.stringValue else {
                return JSONRPCResponse(id: request.id, error: .invalidParams("Missing 'name' parameter"))
            }
            let arguments = request.params?["arguments"]?.objectValue ?? [:]
            let result = await tools.call(name: name, arguments: arguments)
            return JSONRPCResponse(id: request.id, result: result.toJSON())

        default:
            if request.isNotification { return nil }
            return JSONRPCResponse(id: request.id, error: .methodNotFound(request.method))
        }
    }

    static func serialize(_ response: JSONRPCResponse) -> String {
        guard let data = try? JSONEncoder().encode(response),
              let string = String(data: data, encoding: .utf8)
        else { return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"# }
        return string
    }

    /// stdioループ（paperd-mcp CLIのエントリポイント）
    public func runStdioLoop() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let response = await handle(line: line) {
                print(response)
                // フラッシュはfflushのみ。synchronizeFile()（fsync）はstdoutがパイプのとき
                // NSFileHandleOperationExceptionでSIGABRTする（MCPは常にパイプ通信。
                // 単発パイプのE2Eでは応答後のクラッシュが見えず長期間潜伏していたバグ）
                fflush(stdout)
            }
        }
    }
}

/// ツール呼び出し結果（MCP CallToolResult）
public struct ToolCallResult: Sendable {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    public static func error(_ message: String) -> ToolCallResult {
        ToolCallResult(text: message, isError: true)
    }

    func toJSON() -> JSONValue {
        .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "isError": .bool(isError),
        ])
    }
}
