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
            // ソースのみ上書き（.venv は温存し、pip install -e の冪等性に任せる → docs/01 3.3節）
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            for item in ["pyproject.toml", "src"] {
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

/// Python 3.11+ バイナリの探索（→ docs/01 3.3節）。
///
/// 探索戦略:
/// 1. Homebrew `python@X.Y/bin/pythonX.Y` を `/opt/homebrew/opt`（Apple Silicon）と
///    `/usr/local/opt`（Intel）から glob で列挙、X.Y の降順で試行
/// 2. `/opt/homebrew/bin/python3.*` と `/usr/local/bin/python3.*` を同様に glob
/// 3. `~/.pyenv/shims/python3.*`
/// 4. `which python3` で PATH 探索
/// 5. `/usr/bin/python3`（macOS 同梱、通常 3.9 系で minVersion で除外）
///
/// バージョンリストをハードコードしないので Python 3.14 / 3.15 が出ても自動追従する。
/// 検証は `python -c "import sys;sys.exit(0 if sys.version_info >= (3,11) else 1)"`。
/// 結果は process 寿命でキャッシュ（SwiftUI body 再評価ごとに fork/exec しない）。
public enum PythonLocator {
    public static let minVersion = (major: 3, minor: 11)

    nonisolated(unsafe) private static var cachedResult: String??
    private static let cacheLock = NSLock()

    /// キャッシュ済みなら即返す。初回は `discover()` を呼んで結果（nil 含む）をキャッシュ。
    public static func find() -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cachedResult { return cached }
        let found = discover()
        cachedResult = .some(found)
        return found
    }

    /// キャッシュを破棄。ユーザが Python を後追いでインストールした場合などに呼ぶ。
    public static func invalidateCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cachedResult = nil
    }

    private static func discover() -> String? {
        let fm = FileManager.default
        // 1. Homebrew `opt/python@X.Y/bin/pythonX.Y`（降順）
        for optRoot in ["/opt/homebrew/opt", "/usr/local/opt"] {
            for entry in formulaeAt(optRoot).sorted(by: descendingVersionOrder) {
                let version = entry.replacingOccurrences(of: "python@", with: "")
                let path = "\(optRoot)/\(entry)/bin/python\(version)"
                if fm.isExecutableFile(atPath: path), satisfiesMinVersion(at: path) {
                    return path
                }
            }
        }
        // 2. Homebrew 直下 `bin/python3.X`（降順）
        for binDir in ["/opt/homebrew/bin", "/usr/local/bin"] {
            for entry in pythonBinariesAt(binDir).sorted(by: descendingVersionOrder) {
                let path = "\(binDir)/\(entry)"
                if fm.isExecutableFile(atPath: path), satisfiesMinVersion(at: path) {
                    return path
                }
            }
        }
        // 3. pyenv shims
        let home = fm.homeDirectoryForCurrentUser.path
        let pyenv = "\(home)/.pyenv/shims"
        for entry in pythonBinariesAt(pyenv).sorted(by: descendingVersionOrder) {
            let path = "\(pyenv)/\(entry)"
            if fm.isExecutableFile(atPath: path), satisfiesMinVersion(at: path) {
                return path
            }
        }
        // 4. PATH 上の探索
        for name in ["python3", "python"] {
            if let path = which(name), satisfiesMinVersion(at: path) { return path }
        }
        // 5. /usr/bin/python3（macOS system）
        if fm.isExecutableFile(atPath: "/usr/bin/python3"),
           satisfiesMinVersion(at: "/usr/bin/python3") {
            return "/usr/bin/python3"
        }
        return nil
    }

    private static func formulaeAt(_ optRoot: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: optRoot))?
            .filter { $0.hasPrefix("python@") } ?? []
    }

    private static func pythonBinariesAt(_ dir: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir))?
            .filter { $0.hasPrefix("python3.") && !$0.contains("-") } ?? []  // exclude python3.X-config
    }

    /// 文字列降順だと 3.9 > 3.13 になるので、数値比較する
    private static func descendingVersionOrder(_ lhs: String, _ rhs: String) -> Bool {
        versionTuple(lhs) > versionTuple(rhs)
    }

    private static func versionTuple(_ name: String) -> (Int, Int) {
        let trimmed = name
            .replacingOccurrences(of: "python@", with: "")
            .replacingOccurrences(of: "python", with: "")
        let parts = trimmed.split(separator: ".").compactMap { Int($0) }
        return (parts.first ?? 0, parts.dropFirst().first ?? 0)
    }

    static func satisfiesMinVersion(at path: String) -> Bool {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: path)
        check.arguments = [
            "-c",
            "import sys;sys.exit(0 if sys.version_info >= (\(minVersion.major),\(minVersion.minor)) else 1)",
        ]
        // stdout/stderr を /dev/null へ送る（Pipe で受けて読まないとバッファ満杯デッドロックの罠）
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        do {
            try check.run()
            check.waitUntilExit()
            return check.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return nil
        }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}

/// 使用する workerDir を解決する（→ docs/01 3.3節）。
///
/// API は 2 つに分かれる:
///
/// - ``locate()`` — **副作用なし**。`pyproject.toml` が既に存在する workerDir を返すだけ。
///   SwiftUI computed property / status 定期 poll など hot path で使う。
/// - ``locateOrDeploy()`` — `locate()` が nil なら配布バンドル同梱の `Resources/worker` を
///   Application Support へ展開して返す。展開 I/O エラーは throw。アプリ起動時に 1 度だけ呼ぶ。
///
/// `locate()` の dev candidate は、バイナリの実位置から親方向に最大 4 階層さかのぼり、
/// 最初に `worker/pyproject.toml` が見つかったディレクトリを返す。これで
/// `.app` (`.build/Paperd.app`) も `swift run` (`.build/debug/`) も
/// CLI/MCP (`.build/arm64-apple-macosx/debug/`) も同じロジックで repo の `worker/` に到達できる。
///
/// 任意ディレクトリ指定（`PAPERD_WORKER_DIR` や設定画面のパス選択）は廃止。worker 実体は
/// 配布バンドル同梱版か開発リポジトリ版のどちらかしか有効ではないため
public enum WorkerLocator {
    /// 副作用なし。`pyproject.toml` が現に存在する workerDir を返す。なければ nil。
    public static func locate() -> URL? {
        let fm = FileManager.default
        // 1. dev candidate: バイナリの実位置から親方向に最大 4 階層さかのぼる
        var cur = Bundle.main.bundleURL
        for _ in 0..<5 {  // 自分自身も含めて 5 段試行（cur 自体 → 4 階層上）
            let candidate = cur.appendingPathComponent("worker")
            if fm.fileExists(atPath: candidate.appendingPathComponent("pyproject.toml").path) {
                return candidate
            }
            cur = cur.deletingLastPathComponent()
        }
        // 2. 既に App Support に展開済みなら拾う
        let dest = WorkerDeployment.defaultDestDir
        if fm.fileExists(atPath: dest.appendingPathComponent("pyproject.toml").path) {
            return dest
        }
        return nil
    }

    /// 配布バンドル同梱の `Resources/worker` を Application Support へ展開して URL を返す。
    ///
    /// 同梱ワーカーが存在する場合は、既に App Support に展開済みの worker より同梱版を優先し、
    /// `deployIfNeeded()` のバージョン比較を必ず通す。Homebrew / .app 更新後に古い App Support
    /// worker を先に拾ってしまうと、アプリ本体と worker の期待バージョンがずれて reindex/embed が
    /// `MODEL_NOT_READY` で失敗するため。
    ///
    /// 同梱ワーカーが存在しない開発実行では `locateFallback`（既定は `locate()`）で dev / 既存
    /// App Support worker を探す。展開時の I/O エラーは throw。
    public static func locateOrDeploy(
        bundleURL: URL = Bundle.main.bundleURL,
        resourceURL: URL? = Bundle.main.resourceURL,
        destDir: URL = WorkerDeployment.defaultDestDir,
        locateFallback: () -> URL? = { locate() }
    ) throws -> URL? {
        let fm = FileManager.default
        let bundledCandidates: [URL] = [
            resourceURL?.appendingPathComponent("worker"),
            bundleURL.deletingLastPathComponent().appendingPathComponent("Resources/worker"),
        ].compactMap { $0 }
        for src in bundledCandidates
        where fm.fileExists(atPath: src.appendingPathComponent("pyproject.toml").path) {
            return try WorkerDeployment(bundledDir: src, destDir: destDir).deployIfNeeded()
        }
        return locateFallback()
    }
}
