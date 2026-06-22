import Foundation
import Testing
import PaperdCore

/// Claudeスキルのインストール（→ docs/07 6.1節）
@Suite("SkillInstaller")
struct SkillInstallerTests {
    func makeDirs() throws -> (source: URL, dest: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID().uuidString)")
        let source = root.appendingPathComponent("bundle")
        let dest = root.appendingPathComponent("claude-skills")
        for name in ["paperd-research", "paperd-cite"] {
            let dir = source.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("---\nname: \(name)\n---\nbody v1".utf8).write(to: dir.appendingPathComponent("SKILL.md"))
        }
        // SKILL.mdを持たないフォルダは対象外
        try FileManager.default.createDirectory(at: source.appendingPathComponent("not-a-skill"), withIntermediateDirectories: true)
        return (source, dest, root)
    }

    @Test("一覧・インストール・状態遷移")
    func installFlow() throws {
        let (source, dest, root) = try makeDirs()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = SkillInstaller(sourceDir: source, destDir: dest)

        #expect(installer.bundledSkills() == ["paperd-cite", "paperd-research"], "SKILL.md持ちのみ")
        #expect(installer.overallStatus() == .notInstalled)

        try installer.installAll()
        #expect(installer.overallStatus() == .installed)
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("paperd-research/SKILL.md").path))

        // 同梱側が更新されたら needsUpdate → 再インストールで installed
        try Data("---\nname: paperd-research\n---\nbody v2".utf8)
            .write(to: source.appendingPathComponent("paperd-research/SKILL.md"))
        #expect(installer.overallStatus() == .needsUpdate)
        try installer.install("paperd-research")
        #expect(installer.overallStatus() == .installed)
        let installed = String(data: FileManager.default.contents(
            atPath: dest.appendingPathComponent("paperd-research/SKILL.md").path)!, encoding: .utf8)
        #expect(installed?.contains("body v2") == true, "上書きされる")
    }
}

/// 同梱ワーカーの展開（→ docs/01 3.3節）
@Suite("WorkerDeployment")
struct WorkerDeploymentTests {
    func makeBundled(_ root: URL, version: String) throws -> URL {
        let dir = root.appendingPathComponent("bundled-worker")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src/paperd_worker"), withIntermediateDirectories: true)
        try Data("[project]\nname = \"paperd-worker\"\nversion = \"\(version)\"\n".utf8)
            .write(to: dir.appendingPathComponent("pyproject.toml"))
        try Data("lock".utf8).write(to: dir.appendingPathComponent("uv.lock"))
        try Data("__version__ = \"\(version)\"".utf8)
            .write(to: dir.appendingPathComponent("src/paperd_worker/__init__.py"))
        return dir
    }

    @Test("初回展開・同バージョンはスキップ・更新で上書き（.venv温存）")
    func deployLifecycle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deploy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = try makeBundled(root, version: "1.0.0")
        let dest = root.appendingPathComponent("appsupport-worker")
        let deployment = WorkerDeployment(bundledDir: bundled, destDir: dest)

        // 初回展開
        let deployed = try #require(try deployment.deployIfNeeded())
        #expect(WorkerDeployment.version(of: deployed) == "1.0.0")

        // .venvを置いて同バージョン再実行 → 触られない
        let venvMarker = dest.appendingPathComponent(".venv/marker")
        try FileManager.default.createDirectory(at: dest.appendingPathComponent(".venv"), withIntermediateDirectories: true)
        try Data("env".utf8).write(to: venvMarker)
        _ = try deployment.deployIfNeeded()
        #expect(FileManager.default.fileExists(atPath: venvMarker.path), ".venvは温存")

        // バージョンアップ → ソース上書き・.venv温存
        try Data("[project]\nname = \"paperd-worker\"\nversion = \"1.1.0\"\n".utf8)
            .write(to: bundled.appendingPathComponent("pyproject.toml"))
        _ = try deployment.deployIfNeeded()
        #expect(WorkerDeployment.version(of: dest) == "1.1.0")
        #expect(FileManager.default.fileExists(atPath: venvMarker.path), ".venvは温存")
    }

    @Test("同梱ワーカーが無ければnil（開発ビルド等）")
    func noBundledWorker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deploy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let deployment = WorkerDeployment(
            bundledDir: root.appendingPathComponent("missing"),
            destDir: root.appendingPathComponent("dest"))
        #expect(try deployment.deployIfNeeded() == nil)
    }

    @Test("locateOrDeployは既存App Supportより同梱ワーカーを優先して更新する")
    func locateOrDeployPrefersBundledWorkerOverExistingFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deploy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let resourceURL = root.appendingPathComponent("Resources")
        let bundled = resourceURL.appendingPathComponent("worker")
        try FileManager.default.createDirectory(at: bundled.appendingPathComponent("src/paperd_worker"), withIntermediateDirectories: true)
        try Data("[project]\nname = \"paperd-worker\"\nversion = \"2.0.0\"\n".utf8)
            .write(to: bundled.appendingPathComponent("pyproject.toml"))
        try Data("__version__ = \"2.0.0\"".utf8)
            .write(to: bundled.appendingPathComponent("src/paperd_worker/__init__.py"))

        let existing = root.appendingPathComponent("appsupport-worker")
        try FileManager.default.createDirectory(at: existing.appendingPathComponent("src/paperd_worker"), withIntermediateDirectories: true)
        try Data("[project]\nname = \"paperd-worker\"\nversion = \"1.0.0\"\n".utf8)
            .write(to: existing.appendingPathComponent("pyproject.toml"))
        try Data("__version__ = \"1.0.0\"".utf8)
            .write(to: existing.appendingPathComponent("src/paperd_worker/__init__.py"))
        let venvMarker = existing.appendingPathComponent(".venv/marker")
        try FileManager.default.createDirectory(at: existing.appendingPathComponent(".venv"), withIntermediateDirectories: true)
        try Data("env".utf8).write(to: venvMarker)

        let resolved = try #require(try WorkerLocator.locateOrDeploy(
            bundleURL: root.appendingPathComponent("Paperd.app"),
            resourceURL: resourceURL,
            destDir: existing,
            locateFallback: { existing }
        ))

        #expect(resolved == existing)
        #expect(WorkerDeployment.version(of: existing) == "2.0.0")
        #expect(FileManager.default.fileExists(atPath: venvMarker.path), ".venvは温存")
    }
}
