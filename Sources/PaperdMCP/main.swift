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
    let message = "Launch the paperd app once to initialize the library (\(libraryRoot.path) not found)."
    let tools = PaperdTools(
        store: try! LibraryStore.create(at: FileManager.default.temporaryDirectory.appendingPathComponent("paperd-uninitialized-\(UUID().uuidString)")),
        embedderProvider: { nil },
        resolver: { _ in throw MetadataError.network(source: "paperd", message: message) }
    )
    let server = MCPServer(tools: tools)
    await server.runStdioLoop()
    exit(0)
}

let resolver = MetadataResolver.live(
    mailto: ProcessInfo.processInfo.environment["PAPERD_MAILTO"],
    s2APIKey: ProcessInfo.processInfo.environment["PAPERD_S2_API_KEY"]
)

// 起動時に 1 回だけ workerDir を解決（必要なら配布バンドルから App Support へ展開する）。
// 失敗しても MCP 自体は起動して FTS5 のみで応答する（→ docs/07 5節）
let workerDirectory: URL? = (try? WorkerLocator.locateOrDeploy()) ?? WorkerLocator.locate()

let tools = PaperdTools(
    store: store,
    // semantic検索のクエリembedding: worker.lock経由で既存ワーカーを再利用、
    // なければ起動時にキャプチャした workerDir でオンデマンド起動（アイドル10分で自動終了
    // → docs/01 3.2節, docs/07 4節）
    embedderProvider: {
        if let client = WorkerLock.reusableClient() { return client }
        guard let workerDir = workerDirectory else {
            return nil  // ワーカー未セットアップ → FTS5のみで応答
        }
        let manager = WorkerProcessManager(workerDirectory: workerDir)
        return try? await manager.startOrReuseVerified(idleTimeout: 600)
    },
    resolver: { try await resolver.resolve($0) },
    accessLog: MCPAccessLog()  // 最終アクセスの可視化（→ docs/07 6節）
)
let server = MCPServer(tools: tools)
await server.runStdioLoop()
