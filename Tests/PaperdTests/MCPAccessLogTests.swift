import Foundation
import Testing
import PaperdCore
import PaperdMCPKit

/// MCP最終アクセスの記録（→ docs/07 6節）
@Suite("MCPアクセスログ")
struct MCPAccessLogTests {
    @Test("記録と読み出しのラウンドトリップ")
    func roundtrip() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-access-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: path) }
        let log = MCPAccessLog(path: path)
        #expect(log.lastAccess() == nil)
        log.record(tool: "search_papers")
        let entry = log.lastAccess()
        #expect(entry?.tool == "search_papers")
        #expect(entry?.at.isEmpty == false)
    }

    @Test("ツール呼び出しで最終アクセスが記録される")
    func toolCallRecords() async throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let path = root.appendingPathComponent("mcp-access.json")
        let tools = PaperdTools(
            store: store,
            embedderProvider: { nil },
            resolver: { _ in sampleResolved() },
            accessLog: MCPAccessLog(path: path)
        )
        _ = await tools.call(name: "search_papers", arguments: ["query": .string("test")])
        #expect(MCPAccessLog(path: path).lastAccess()?.tool == "search_papers")
    }
}
