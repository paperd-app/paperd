import Foundation

/// ワーカー多重起動防止のロックファイル（→ docs/01 3.2節）。
/// `~/Library/Application Support/paperd/worker.lock` にPID + ポート + トークンを保持し、
/// 既存ワーカーが生きていれば再利用する。
public struct WorkerLock: Codable, Equatable, Sendable {
    public var pid: Int32
    public var port: Int
    public var token: String

    public init(pid: Int32, port: Int, token: String) {
        self.pid = pid
        self.port = port
        self.token = token
    }

    public static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/paperd/worker.lock")
    }

    public static func read(at path: URL = defaultPath) -> WorkerLock? {
        guard let data = FileManager.default.contents(atPath: path.path) else { return nil }
        return try? JSONDecoder().decode(WorkerLock.self, from: data)
    }

    public func write(to path: URL = defaultPath) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: path, options: .atomic)
    }

    public static func remove(at path: URL = defaultPath) {
        try? FileManager.default.removeItem(at: path)
    }

    /// プロセスが生存しているか（kill -0 相当）
    public var isProcessAlive: Bool {
        kill(pid, 0) == 0
    }

    /// 稼働中のワーカーを停止する（SIGTERM + lock掃除を待つ → docs/09 9節 手動停止）
    public static func terminateRunningWorker(at path: URL = defaultPath) async {
        guard let lock = read(at: path), lock.isProcessAlive else {
            remove(at: path)
            return
        }
        kill(lock.pid, SIGTERM)
        for _ in 0..<50 {  // 最大5秒、graceful shutdown完了（lock掃除）を待つ
            if read(at: path) == nil { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        remove(at: path)
    }

    /// 生きている既存ワーカーのクライアントを返す。死んでいればロックを掃除してnil
    public static func reusableClient(at path: URL = defaultPath, http: HTTPClient = URLSessionHTTPClient()) -> WorkerClient? {
        guard let lock = read(at: path) else { return nil }
        guard lock.isProcessAlive else {
            remove(at: path)
            return nil
        }
        return WorkerClient(port: lock.port, token: lock.token, http: http)
    }
}

/// Pythonワーカープロセスの起動（→ docs/01 3節）。
/// `<workerDir>/.venv/bin/python -m paperd_worker` を子プロセスとして起動し、標準出力の `{"port": N}` 行を読み取る。
public struct WorkerProcessManager {
    public let workerDirectory: URL
    public let lockPath: URL

    public init(workerDirectory: URL, lockPath: URL = WorkerLock.defaultPath) {
        self.workerDirectory = workerDirectory
        self.lockPath = lockPath
    }

    /// 既存ワーカーを再利用、なければ起動する。
    /// **再利用時は/healthのバージョンを照合し、不一致なら旧プロセスを終了して起動し直す**
    /// （コード更新後に旧ワーカーが残留し、新しいオプションが黙って無視される事故の防止 → docs/01 3.2節）。
    public func startOrReuseVerified(
        idleTimeout: Int = 0,
        expectedVersion: String = WorkerClient.expectedWorkerVersion
    ) async throws -> WorkerClient {
        if let client = WorkerLock.reusableClient(at: lockPath) {
            if let health = try? await client.health(), health.version == expectedVersion {
                return client
            }
            // 旧バージョン（または応答不能）のワーカー: 終了して入れ替える
            if let lock = WorkerLock.read(at: lockPath) {
                kill(lock.pid, SIGTERM)
                for _ in 0..<50 {  // 最大5秒、lock掃除（= graceful shutdown完了）を待つ
                    if WorkerLock.read(at: lockPath) == nil { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            WorkerLock.remove(at: lockPath)
        }
        return try startOrReuse(idleTimeout: idleTimeout)
    }

    /// 既存ワーカーを再利用、なければ起動する（バージョン照合なし）。
    /// - Parameter idleTimeout: MCP起源のオンデマンド起動では既定600秒（→ docs/01 3.2節）
    public func startOrReuse(idleTimeout: Int = 0) throws -> WorkerClient {
        if let client = WorkerLock.reusableClient(at: lockPath) {
            return client
        }
        let token = UUID().uuidString
        let process = Process()
        // <workerDir>/.venv/bin/python から `paperd_worker` モジュールを直接起動（→ docs/01 3.3節）
        let venvPython = workerDirectory.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: venvPython.path) else {
            throw WorkerClient.WorkerAPIError(
                code: "MODEL_NOT_READY",
                message: "Python virtual environment not found at \(venvPython.path). Open the app's Settings > Worker and run setup.",
                statusCode: 0)
        }
        process.executableURL = venvPython
        var arguments = ["-m", "paperd_worker", "--token", token, "--port", "0", "--lock-file", lockPath.path]
        if idleTimeout > 0 {
            arguments += ["--idle-timeout", String(idleTimeout)]
        }
        process.arguments = arguments
        process.currentDirectoryURL = workerDirectory
        let stdout = Pipe()
        process.standardOutput = stdout
        try process.run()

        // ワーカーは起動時に1行JSONでポートを通知する（→ docs/01 3.1節）
        let handle = stdout.fileHandleForReading
        var buffer = Data()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[..<newline]
                if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   let port = json["port"] as? Int {
                    return WorkerClient(port: port, token: token)
                }
                break
            }
        }
        process.terminate()
        throw WorkerClient.WorkerAPIError(code: "INTERNAL", message: "Failed to start worker (no port notification received)", statusCode: 0)
    }
}
