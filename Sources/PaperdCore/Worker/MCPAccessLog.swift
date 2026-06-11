import Foundation

/// MCPの最終アクセス記録（→ docs/07 6節）。
/// MCPサーバはクライアントが起動する子プロセスであり、アプリ側から死活の直接確認は
/// できないため、ツール呼び出しの痕跡をマシンローカルのファイルに残して可視化する。
public struct MCPAccessLog: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var tool: String
        public var at: String

        public init(tool: String, at: String = PaperdDates.nowString()) {
            self.tool = tool
            self.at = at
        }
    }

    public let path: URL

    public static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/paperd/mcp-last-access.json")
    }

    public init(path: URL = defaultPath) {
        self.path = path
    }

    /// ベストエフォートで記録する（失敗してもツール呼び出しを妨げない）
    public func record(tool: String) {
        let entry = Entry(tool: tool)
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entry).write(to: path, options: .atomic)
    }

    public func lastAccess() -> Entry? {
        guard let data = FileManager.default.contents(atPath: path.path) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }
}
