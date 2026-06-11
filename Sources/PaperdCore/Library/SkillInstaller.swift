import Foundation

/// 同梱Claudeスキルのインストール（→ docs/07 6.1節）。
/// アプリバンドルの skills/ から ~/.claude/skills/ へコピーする。UIに依存しないテスト可能な実装。
public struct SkillInstaller: Sendable {
    public enum Status: Equatable, Sendable {
        case notInstalled
        case installed
        /// 同梱版とインストール済みの内容が異なる（アプリ更新後など）
        case needsUpdate
    }

    /// 同梱スキルのフォルダ（アプリバンドルの Contents/Resources/skills）
    public let sourceDir: URL
    /// インストール先（既定: ~/.claude/skills）
    public let destDir: URL

    public init(sourceDir: URL, destDir: URL = defaultDestDir) {
        self.sourceDir = sourceDir
        self.destDir = destDir
    }

    public static var defaultDestDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills")
    }

    /// 同梱スキル名の一覧（SKILL.mdを持つサブフォルダ）
    public func bundledSkills() -> [String] {
        let fm = FileManager.default
        let subdirs = (try? fm.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil)) ?? []
        return subdirs
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }
            .map(\.lastPathComponent)
            .sorted()
    }

    public func status(of name: String) -> Status {
        let source = sourceDir.appendingPathComponent(name).appendingPathComponent("SKILL.md")
        let installed = destDir.appendingPathComponent(name).appendingPathComponent("SKILL.md")
        guard let installedData = FileManager.default.contents(atPath: installed.path) else {
            return .notInstalled
        }
        let sourceData = FileManager.default.contents(atPath: source.path)
        return installedData == sourceData ? .installed : .needsUpdate
    }

    /// 全体の状態（未インストールが1つでもあればnotInstalled、差分があればneedsUpdate）
    public func overallStatus() -> Status {
        let statuses = bundledSkills().map(status(of:))
        if statuses.isEmpty || statuses.contains(.notInstalled) { return .notInstalled }
        if statuses.contains(.needsUpdate) { return .needsUpdate }
        return .installed
    }

    /// スキルを上書きインストールする
    public func install(_ name: String) throws {
        let fm = FileManager.default
        let source = sourceDir.appendingPathComponent(name)
        let dest = destDir.appendingPathComponent(name)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: source, to: dest)
    }

    public func installAll() throws {
        for name in bundledSkills() {
            try install(name)
        }
    }
}
