import Foundation
import Testing
import PaperdCore

/// Claudeサブエージェント定義のインストール（→ docs/07 6.2節）
@Suite("AgentInstaller")
struct AgentInstallerTests {
    func makeDirs() throws -> (source: URL, dest: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString)")
        let source = root.appendingPathComponent("bundle")
        let dest = root.appendingPathComponent("claude-agents")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for name in ["paperd-web-researcher", "paperd-citation-analyst"] {
            try Data("---\nname: \(name)\nmodel: sonnet\n---\nbody v1".utf8)
                .write(to: source.appendingPathComponent("\(name).md"))
        }
        // .md 以外のファイルは対象外
        try Data("not an agent".utf8).write(to: source.appendingPathComponent("README.txt"))
        // ディレクトリ名が .md で終わっても対象外（通常ファイルのみ拾う）
        try FileManager.default.createDirectory(at: source.appendingPathComponent("bundle.md"), withIntermediateDirectories: true)
        // 隠しファイル（AppleDouble等）も対象外
        try Data("apple double".utf8).write(to: source.appendingPathComponent("._paperd-web-researcher.md"))
        return (source, dest, root)
    }

    @Test("一覧・インストール・状態遷移（フラットな .md ファイル）")
    func installFlow() throws {
        let (source, dest, root) = try makeDirs()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = AgentInstaller(sourceDir: source, destDir: dest)

        // 通常の .md ファイルのみ（非.md・.mdディレクトリ・隠しファイルは除外）・拡張子除去・ソート
        #expect(installer.bundledAgents() == ["paperd-citation-analyst", "paperd-web-researcher"])
        #expect(installer.overallStatus() == .notInstalled)

        try installer.installAll()
        #expect(installer.overallStatus() == .installed)
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("paperd-web-researcher.md").path))
        // 非.md / .mdディレクトリ / 隠しファイルはインストールされない
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("README.txt").path))
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("bundle.md").path))
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("._paperd-web-researcher.md").path))

        // 同梱側が更新されたら needsUpdate → 再インストールで installed（冪等な上書き）
        try Data("---\nname: paperd-web-researcher\nmodel: sonnet\n---\nbody v2".utf8)
            .write(to: source.appendingPathComponent("paperd-web-researcher.md"))
        #expect(installer.overallStatus() == .needsUpdate)
        try installer.install("paperd-web-researcher")
        #expect(installer.overallStatus() == .installed)
        let installed = String(data: FileManager.default.contents(
            atPath: dest.appendingPathComponent("paperd-web-researcher.md").path)!, encoding: .utf8)
        #expect(installed?.contains("body v2") == true, "上書きされる")
    }
}
