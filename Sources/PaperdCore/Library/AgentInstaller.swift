import Foundation

/// 同梱Claudeサブエージェント定義のインストール（→ docs/07 6.2節）。
/// アプリバンドルの agents/ から ~/.claude/agents/ へコピーする。UIに依存しないテスト可能な実装。
///
/// スキル（`<name>/SKILL.md` のサブディレクトリ）と異なり、エージェントは**フラットな単一ファイル**
/// `<name>.md` で、`~/.claude/agents/<name>.md` に置く。この構造差のため SkillInstaller とは別構造体にする。
public struct AgentInstaller: Sendable {
    public enum Status: Equatable, Sendable {
        case notInstalled
        case installed
        /// 同梱版とインストール済みの内容が異なる（アプリ更新後など）
        case needsUpdate
    }

    /// 同梱エージェントのフォルダ（アプリバンドルの Contents/Resources/agents）
    public let sourceDir: URL
    /// インストール先（既定: ~/.claude/agents）
    public let destDir: URL

    public init(sourceDir: URL, destDir: URL = defaultDestDir) {
        self.sourceDir = sourceDir
        self.destDir = destDir
    }

    public static var defaultDestDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/agents")
    }

    /// 同梱エージェント名の一覧（トップレベルの**通常ファイル** `*.md` のファイル名から拡張子を除いたもの）。
    /// SkillInstaller は `SKILL.md` 存在でディレクトリ/隠しファイルを構造的に除外するが、こちらはフラットな
    /// `*.md` を拾うため、隠しファイル（`.DS_Store` / AppleDouble `._x.md`）とディレクトリ（`foo.md/`）を明示的に除く。
    public func bundledAgents() -> [String] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: sourceDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter { $0.pathExtension == "md" }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    public func status(of name: String) -> Status {
        let source = sourceDir.appendingPathComponent("\(name).md")
        let installed = destDir.appendingPathComponent("\(name).md")
        guard let installedData = FileManager.default.contents(atPath: installed.path) else {
            return .notInstalled
        }
        let sourceData = FileManager.default.contents(atPath: source.path)
        return installedData == sourceData ? .installed : .needsUpdate
    }

    /// 全体の状態（未インストールが1つでもあればnotInstalled、差分があればneedsUpdate）
    public func overallStatus() -> Status {
        let statuses = bundledAgents().map(status(of:))
        if statuses.isEmpty || statuses.contains(.notInstalled) { return .notInstalled }
        if statuses.contains(.needsUpdate) { return .needsUpdate }
        return .installed
    }

    /// エージェント定義を上書きインストールする
    public func install(_ name: String) throws {
        let fm = FileManager.default
        let source = sourceDir.appendingPathComponent("\(name).md")
        let dest = destDir.appendingPathComponent("\(name).md")
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: source, to: dest)
    }

    public func installAll() throws {
        for name in bundledAgents() {
            try install(name)
        }
    }
}
