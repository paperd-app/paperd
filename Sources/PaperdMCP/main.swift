import Foundation
import PaperdCore
import PaperdMCPKit

// paperd-mcp: stdioで動作するMCPサーバCLI（→ docs/07）。
// アプリ非起動時も単独で動作する。ライブラリ未初期化はツール呼び出し時にエラーで案内する。

let libraryRoot: URL
if let env = ProcessInfo.processInfo.environment["PAPERD_LIBRARY"] {
    libraryRoot = URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
} else {
    libraryRoot = LibraryLayout.defaultRoot
}

let store: LibraryStore
do {
    store = try LibraryStore.open(at: libraryRoot)
} catch {
    // ライブラリ未初期化でもMCPハンドシェイクは成立させ、ツール呼び出し時に案内を返す（→ docs/07 5節）
    FileHandle.standardError.write(Data("paperd-mcp: \(error)\n".utf8))
    let message = "paperd アプリを一度起動してライブラリを初期化してください（\(libraryRoot.path) が見つかりません）。"
    let tools = PaperdTools(
        store: try! LibraryStore.create(at: FileManager.default.temporaryDirectory.appendingPathComponent("paperd-uninitialized-\(UUID().uuidString)")),
        embedderProvider: { nil },
        resolver: { _ in throw MetadataError.network(source: "paperd", message: message) }
    )
    let server = MCPServer(tools: tools)
    await server.runStdioLoop()
    exit(0)
}

// semantic検索のクエリembedding: worker.lock経由で既存ワーカーを再利用、
// なければオンデマンド起動（アイドル10分で自動終了 → docs/01 3.2節, docs/07 4節）。
let embedderProvider: @Sendable () async -> QueryEmbedder? = {
    if let client = WorkerLock.reusableClient() {
        return client
    }
    let workerDir = ProcessInfo.processInfo.environment["PAPERD_WORKER_DIR"]
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    guard let workerDir, FileManager.default.fileExists(atPath: workerDir.path) else {
        return nil  // ワーカー未セットアップ → FTS5のみで応答（→ docs/07 5節）
    }
    let manager = WorkerProcessManager(workerDirectory: workerDir)
    return try? await manager.startOrReuseVerified(idleTimeout: 600)
}

let resolver = MetadataResolver.live(
    mailto: ProcessInfo.processInfo.environment["PAPERD_MAILTO"],
    s2APIKey: ProcessInfo.processInfo.environment["PAPERD_S2_API_KEY"]
)

let tools = PaperdTools(
    store: store,
    embedderProvider: embedderProvider,
    resolver: { try await resolver.resolve($0) },
    accessLog: MCPAccessLog()  // 最終アクセスの可視化（→ docs/07 6節）
)
let server = MCPServer(tools: tools)
await server.runStdioLoop()
