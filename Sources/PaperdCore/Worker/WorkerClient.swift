import Foundation

/// PythonワーカーHTTP APIクライアント（→ docs/05 3節）。
/// 127.0.0.1 + Authorizationトークンの枠組み（→ docs/01 3.1節）。
public struct WorkerClient: Sendable {
    /// アプリが期待するワーカーのバージョン（worker/src/paperd_worker/__init__.py と同期。
    /// lock再利用時の旧プロセス検出に使う → docs/01 3.2節）
    public static let expectedWorkerVersion = "0.2.1"

    public let baseURL: URL
    public let token: String
    let http: HTTPClient

    public init(port: Int, token: String, http: HTTPClient = URLSessionHTTPClient()) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.token = token
        self.http = http
    }

    public init(baseURL: URL, token: String, http: HTTPClient = URLSessionHTTPClient()) {
        self.baseURL = baseURL
        self.token = token
        self.http = http
    }

    var headers: [String: String] {
        ["Authorization": "Bearer \(token)", "Content-Type": "application/json"]
    }

    // MARK: - エラー（→ docs/05 3.5節）

    public struct WorkerAPIError: Error, Equatable, CustomStringConvertible {
        public var code: String
        public var message: String
        public var statusCode: Int

        public init(code: String, message: String, statusCode: Int) {
            self.code = code
            self.message = message
            self.statusCode = statusCode
        }

        public var description: String { "[\(code)] \(message)" }

        /// 恒久的エラーはリトライしない（→ docs/05 3.5節の表）
        public var isPermanent: Bool {
            ["PDF_CORRUPT", "PDF_ENCRYPTED", "PAGE_LIMIT_EXCEEDED", "TIMEOUT", "MODEL_NOT_READY"].contains(code)
        }
    }

    static func parseError(_ response: HTTPResponse) -> WorkerAPIError {
        if let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let code = error["code"] as? String {
            return WorkerAPIError(code: code, message: (error["message"] as? String) ?? "", statusCode: response.statusCode)
        }
        return WorkerAPIError(code: "INTERNAL", message: "HTTP \(response.statusCode)", statusCode: response.statusCode)
    }

    // MARK: - API

    public struct ConvertOptions: Codable, Equatable, Sendable {
        public var ocr: Bool
        public var maxPages: Int
        public var timeoutSec: Int
        /// 強制全ページOCR（ToUnicode CMap破損の文字化け回復 → docs/05 3.1節）
        public var forceOcr: Bool
        /// 数式エンリッチメント（上付き/下付き・数式のLaTeX化 → docs/05 3.1節）
        public var formulaEnrichment: Bool

        enum CodingKeys: String, CodingKey {
            case ocr
            case maxPages = "max_pages"
            case timeoutSec = "timeout_sec"
            case forceOcr = "force_ocr"
            case formulaEnrichment = "formula_enrichment"
        }

        public init(ocr: Bool = false, maxPages: Int = 500, timeoutSec: Int = 900, forceOcr: Bool = false, formulaEnrichment: Bool = false) {
            self.ocr = ocr
            self.maxPages = maxPages
            self.timeoutSec = timeoutSec
            self.forceOcr = forceOcr
            self.formulaEnrichment = formulaEnrichment
        }

        /// 高精度再変換（→ docs/05 5.1節）
        public static let highQuality = ConvertOptions(forceOcr: true, formulaEnrichment: true)
    }

    /// POST /convert（非同期。202でjob_idが返る）
    public func convert(pdfPath: String, outputDir: String, options: ConvertOptions = ConvertOptions()) async throws -> String {
        let body: [String: Any] = [
            "pdf_path": pdfPath,
            "output_dir": outputDir,
            "options": [
                "ocr": options.ocr,
                "max_pages": options.maxPages,
                "timeout_sec": options.timeoutSec,
                "force_ocr": options.forceOcr,
                "formula_enrichment": options.formulaEnrichment,
            ],
        ]
        let response = try await post(path: "/convert", json: body)
        guard let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let jobId = json["job_id"] as? String
        else { throw WorkerAPIError(code: "INTERNAL", message: "job_idがありません", statusCode: response.statusCode) }
        return jobId
    }

    public struct WorkerJobStatus: Equatable, Sendable {
        public var jobId: String
        public var status: String  // queued | running | succeeded | failed
        public var stage: String?
        public var progressPage: Int?
        public var progressTotalPages: Int?
        public var error: WorkerAPIError?
    }

    /// GET /jobs/{id}
    public func jobStatus(_ jobId: String) async throws -> WorkerJobStatus {
        let response = try await get(path: "/jobs/\(jobId)")
        guard let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let status = json["status"] as? String
        else { throw WorkerAPIError(code: "INTERNAL", message: "ジョブ状態の解析に失敗", statusCode: response.statusCode) }
        var error: WorkerAPIError?
        if let e = json["error"] as? [String: Any], let code = e["code"] as? String {
            error = WorkerAPIError(code: code, message: (e["message"] as? String) ?? "", statusCode: 0)
        }
        let progress = json["progress"] as? [String: Any]
        return WorkerJobStatus(
            jobId: (json["job_id"] as? String) ?? jobId,
            status: status,
            stage: json["stage"] as? String,
            progressPage: progress?["page"] as? Int,
            progressTotalPages: progress?["total_pages"] as? Int,
            error: error
        )
    }

    /// 変換完了までポーリングする（2秒間隔 → docs/05 3.2節）
    public func waitForConversion(_ jobId: String, pollIntervalSeconds: Double = 2.0) async throws {
        while true {
            let status = try await jobStatus(jobId)
            switch status.status {
            case "succeeded":
                return
            case "failed":
                throw status.error ?? WorkerAPIError(code: "INTERNAL", message: "変換に失敗", statusCode: 0)
            default:
                try await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
            }
        }
    }

    /// POST /embed（task: passage=索引時 / query=検索時 → docs/05 3.3節）
    public func embed(texts: [String], task: String) async throws -> [[Float]] {
        let response = try await post(path: "/embed", json: ["texts": texts, "task": task])
        guard let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let embeddings = json["embeddings"] as? [[Double]]
        else { throw WorkerAPIError(code: "INTERNAL", message: "embeddingsの解析に失敗", statusCode: response.statusCode) }
        return embeddings.map { $0.map(Float.init) }
    }

    public struct Health: Equatable, Sendable {
        public var status: String
        public var modelLoaded: Bool
        public var version: String
    }

    /// GET /health
    public func health() async throws -> Health {
        let response = try await get(path: "/health")
        guard let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let status = json["status"] as? String
        else { throw WorkerAPIError(code: "INTERNAL", message: "healthの解析に失敗", statusCode: response.statusCode) }
        return Health(
            status: status,
            modelLoaded: (json["model_loaded"] as? Bool) ?? false,
            version: (json["version"] as? String) ?? ""
        )
    }

    // MARK: - 内部

    func get(path: String) async throws -> HTTPResponse {
        let response = try await http.send(HTTPRequest(url: baseURL.appendingPathComponent(path), headers: headers))
        guard response.isSuccess else { throw Self.parseError(response) }
        return response
    }

    func post(path: String, json: [String: Any]) async throws -> HTTPResponse {
        let body = try JSONSerialization.data(withJSONObject: json)
        let response = try await http.send(HTTPRequest(
            method: .post,
            url: baseURL.appendingPathComponent(path),
            headers: headers,
            body: body
        ))
        guard response.isSuccess else { throw Self.parseError(response) }
        return response
    }
}

extension WorkerClient: QueryEmbedder {
    public func embedQuery(_ text: String) async throws -> [Float] {
        let result = try await embed(texts: [text], task: "query")
        guard let first = result.first else {
            throw WorkerAPIError(code: "INTERNAL", message: "空のembedding応答", statusCode: 0)
        }
        return first
    }
}
