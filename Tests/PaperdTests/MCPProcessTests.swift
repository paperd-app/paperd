import Foundation
import Testing
import PaperdCore

/// 実バイナリ・実プロセスでのMCP stdioセッションテスト（→ docs/07 4節）。
/// initialize応答直後のfsyncクラッシュ（実クライアント接続で発覚）のような
/// 「単発パイプのE2Eでは見えない」プロセスレベルのバグを捕まえる。
@Suite("MCP stdioプロセス", .serialized)
struct MCPProcessTests {
    /// テストと同じビルド成果物ディレクトリにある実バイナリ。
    /// Swift Testingではxctestバンドル経由の探索が効かないことがあるため、
    /// ①xctestバンドル ②テストランナーの実行パス ③リポジトリ相対（#filePath） の順で探す
    var mcpBinary: URL? {
        var candidates: [URL] = []
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("paperd-mcp"))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("paperd-mcp"))
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PaperdTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // リポジトリルート
        candidates.append(repoRoot.appendingPathComponent(".build/debug/paperd-mcp"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func readLine(_ handle: FileHandle, buffer: inout Data, deadline: Date) -> String? {
        while Date() < deadline {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                return String(data: line, encoding: .utf8)
            }
            let chunk = handle.availableData
            if chunk.isEmpty {
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }
            buffer.append(chunk)
        }
        return nil
    }

    @Test("実バイナリ: 複数リクエストのセッションが生き続ける（fsyncクラッシュ回帰）")
    func multiRequestSession() throws {
        guard let binary = mcpBinary else {
            Issue.record("paperd-mcpバイナリが見つかりません（swift testの成果物ディレクトリ）")
            return
        }
        let (_, root) = try makeTempLibrary()
        defer { cleanup(root) }

        let process = Process()
        process.executableURL = binary
        var env = ProcessInfo.processInfo.environment
        env["PAPERD_LIBRARY"] = root.path
        process.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        defer { process.terminate() }

        func send(_ json: String) {
            stdin.fileHandleForWriting.write(Data((json + "\n").utf8))
        }
        var buffer = Data()
        let deadline = Date().addingTimeInterval(15)

        send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        let initResponse = try #require(readLine(stdout.fileHandleForReading, buffer: &buffer, deadline: deadline))
        #expect(initResponse.contains("\"paperd\""), Comment(rawValue: initResponse))

        // 実クライアントと同じ後続リクエスト（旧実装はこの時点で死んでいた）
        send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let toolsResponse = try #require(readLine(stdout.fileHandleForReading, buffer: &buffer, deadline: deadline),
                                         "tools/listに応答しない（initialize後にクラッシュ？）")
        #expect(toolsResponse.contains("search_papers"))

        send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_papers","arguments":{"query":"test"}}}"#)
        let callResponse = try #require(readLine(stdout.fileHandleForReading, buffer: &buffer, deadline: deadline))
        #expect(callResponse.contains("\"id\":3") || callResponse.contains("\"id\" : 3"))

        #expect(process.isRunning, "3リクエスト処理後もプロセスが生存している")
    }
}
