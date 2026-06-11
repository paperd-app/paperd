import Foundation

/// 同梱ワーカーの展開（→ docs/01 3.3節）。
/// 配布.appの Contents/Resources/worker を Application Support へ展開し、
/// バージョンが上がったらソースを上書き更新する（.venvは温存）。
public struct WorkerDeployment: Sendable {
    public let bundledDir: URL
    public let destDir: URL

    public init(bundledDir: URL, destDir: URL = defaultDestDir) {
        self.bundledDir = bundledDir
        self.destDir = destDir
    }

    public static var defaultDestDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/paperd/worker")
    }

    /// pyproject.tomlの `version = "x.y.z"` を読む
    public static func version(of workerDir: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: workerDir.appendingPathComponent("pyproject.toml").path),
              let toml = String(data: data, encoding: .utf8) else { return nil }
        for line in toml.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("version") {
                let parts = trimmed.components(separatedBy: "\"")
                if parts.count >= 2 { return parts[1] }
            }
        }
        return nil
    }

    /// 必要なら展開し、使用すべきworkerDirを返す。同梱ワーカーが無ければnil
    @discardableResult
    public func deployIfNeeded() throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundledDir.appendingPathComponent("pyproject.toml").path) else {
            return nil
        }
        let deployedVersion = Self.version(of: destDir)
        let bundledVersion = Self.version(of: bundledDir)
        if deployedVersion == nil || (bundledVersion != nil && bundledVersion != deployedVersion) {
            // ソースのみ上書き（.venvは温存し、uv runの自動同期に任せる → docs/01 3.3節）
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            for item in ["pyproject.toml", "uv.lock", "src"] {
                let source = bundledDir.appendingPathComponent(item)
                guard fm.fileExists(atPath: source.path) else { continue }
                let target = destDir.appendingPathComponent(item)
                if fm.fileExists(atPath: target.path) {
                    try fm.removeItem(at: target)
                }
                try fm.copyItem(at: source, to: target)
            }
        }
        return destDir
    }
}

/// uvバイナリの探索（→ docs/01 3.3節）。
/// GUIアプリのPATHにはhomebrew等が含まれないため、既知の場所を明示的に探す
public enum UVLocator {
    public static func find() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
            "\(home)/.local/bin/uv",
            "\(home)/.cargo/bin/uv",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // PATH上の探索（ターミナル起動時はこちらで見つかる）
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["uv"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        try? which.run()
        which.waitUntilExit()
        if which.terminationStatus == 0,
           let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return path }
        }
        return nil
    }
}
