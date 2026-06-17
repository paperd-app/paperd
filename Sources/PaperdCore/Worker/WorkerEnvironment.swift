import Foundation

/// Python ワーカ環境の構築フロー（→ docs/01 3.3節）。
///
/// 3 段の `Process` 実行を 1 つに束ねたコアロジック:
/// 1. `<python> -m venv .venv`
/// 2. `<venv>/bin/python -m pip install --upgrade pip`
/// 3. `<venv>/bin/python -m pip install --upgrade -e .[ml]`
///
/// UI（SettingsView）からも CLI / セットアップウィザードからも同じ呼び出しで使える。
/// 行出力は `onLine` クロージャで都度通知（log ストリーミング用）。
public struct WorkerEnvironmentSetup: Sendable {
    public let workerDir: URL
    public let python: String

    public init(workerDir: URL, python: String) {
        self.workerDir = workerDir
        self.python = python
    }

    public var venvPython: URL {
        workerDir.appendingPathComponent(".venv/bin/python")
    }

    public func steps() -> [Step] {
        [
            Step(executable: python, args: ["-m", "venv", ".venv"]),
            Step(executable: venvPython.path, args: ["-m", "pip", "install", "--upgrade", "pip"]),
            Step(executable: venvPython.path, args: ["-m", "pip", "install", "--upgrade", "-e", ".[ml]"]),
        ]
    }

    /// 全 step を順に実行。途中で失敗したら `WorkerEnvironmentError.stepFailed` を throw。
    public func run(onLine: @escaping @Sendable (String) -> Void) async throws {
        for step in steps() {
            try await runStep(step, onLine: onLine)
        }
    }

    private func runStep(_ step: Step, onLine: @escaping @Sendable (String) -> Void) async throws {
        onLine("$ \(step.executable) \(step.args.joined(separator: " "))")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: step.executable)
        process.arguments = step.args
        process.currentDirectoryURL = workerDir
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        for try await line in pipe.fileHandleForReading.bytes.lines {
            onLine(line)
        }
        process.waitUntilExit()
        let status = Int(process.terminationStatus)
        if status != 0 {
            throw WorkerEnvironmentError.stepFailed(
                exitCode: status,
                command: "\(step.executable) \(step.args.joined(separator: " "))")
        }
    }

    public struct Step: Sendable {
        public let executable: String
        public let args: [String]
    }
}

public enum WorkerEnvironmentError: Error, LocalizedError, Sendable {
    case stepFailed(exitCode: Int, command: String)

    public var errorDescription: String? {
        switch self {
        case .stepFailed(let code, let cmd):
            return "Setup step failed (exit \(code)): \(cmd)"
        }
    }
}
