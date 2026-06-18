import Foundation

/// 本番用のステージ実行: MetadataResolver + PDFダウンロード + Pythonワーカー（→ docs/04, 05）
public struct LiveStageExecutors: IngestStageExecutors {
    public let resolver: MetadataResolver
    public let http: HTTPClient
    /// ワーカークライアントの供給（遅延起動・再利用は供給側で行う）
    public let workerProvider: @Sendable () async throws -> WorkerClient
    /// Unpaywall用メールアドレス（必須パラメータ → docs/04 9節）。未設定ならUnpaywallはスキップ
    public let unpaywallEmail: String?

    public init(
        resolver: MetadataResolver,
        http: HTTPClient = URLSessionHTTPClient(),
        unpaywallEmail: String? = nil,
        workerProvider: @escaping @Sendable () async throws -> WorkerClient
    ) {
        self.resolver = resolver
        self.http = http
        self.unpaywallEmail = unpaywallEmail
        self.workerProvider = workerProvider
    }

    public func resolve(_ identifier: PaperIdentifier) async throws -> ResolvedMetadata {
        try await resolver.resolve(identifier)
    }

    /// PDF取得の優先順: arXiv直接 → Unpaywall OAリンク → ユーザ提供（→ docs/04 6節）
    public func fetchPDF(meta: ResolvedMetadata, destination: URL) async throws -> Bool {
        var candidates: [String] = []
        if let pdfURL = meta.pdfURL { candidates.append(pdfURL) }
        if let arxivId = meta.arxivId { candidates.append("https://arxiv.org/pdf/\(arxivId)") }
        if let doi = meta.doi, let email = unpaywallEmail,
           let oaURL = try? await unpaywallPDFURL(doi: doi, email: email) {
            candidates.append(oaURL)
        }
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if let response = try? await http.send(HTTPRequest(url: url)), response.isSuccess,
               !response.body.isEmpty {
                try response.body.write(to: destination, options: .atomic)
                return true
            }
        }
        return false  // 全ソース失敗 → metadata_onlyの部分的成功
    }

    /// 直接PDF URLのダウンロード（→ docs/04 2節）
    public func downloadFile(from url: URL, to destination: URL) async throws {
        let response = try await http.send(HTTPRequest(url: url))
        guard response.isSuccess, !response.body.isEmpty else {
            throw IngestError.permanent("Failed to download PDF (HTTP \(response.statusCode)): \(url.absoluteString)")
        }
        try response.body.write(to: destination, options: .atomic)
    }

    func unpaywallPDFURL(doi: String, email: String) async throws -> String? {
        let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
        guard let url = URL(string: "https://api.unpaywall.org/v2/\(encoded)?email=\(email)") else { return nil }
        let response = try await http.send(HTTPRequest(url: url))
        guard response.isSuccess,
              let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let oa = json["best_oa_location"] as? [String: Any]
        else { return nil }
        return oa["url_for_pdf"] as? String
    }

    /// ローカルPDF解決: Crossref bibliographic検索でDOIを確定し、通常の解決フローに帰着（→ docs/04 4節）
    public func resolveBibliographic(title: String, author: String?) async throws -> ResolvedMetadata? {
        guard let doi = try await resolver.crossref.searchByBibliographic(title: title, author: author) else {
            return nil
        }
        return try await resolver.resolve(.doi(doi))
    }

    public func convert(pdfPath: URL, outputDir: URL, options: WorkerClient.ConvertOptions) async throws {
        let worker = try await workerProvider()
        let jobId = try await worker.convert(pdfPath: pdfPath.path, outputDir: outputDir.path, options: options)
        try await worker.waitForConversion(jobId)
    }

    /// embedのバッチサイズ。変換直後のメモリ圧でのML runtime失敗を避けるため一度に送りすぎない
    public static let embedBatchSize = 16

    public func embed(texts: [String]) async throws -> [[Float]] {
        let worker = try await workerProvider()
        var result: [[Float]] = []
        for batch in Self.batches(texts, size: Self.embedBatchSize) {
            result.append(contentsOf: try await worker.embed(texts: batch, task: "passage"))
        }
        return result
    }

    static func batches<T>(_ items: [T], size: Int) -> [[T]] {
        guard size > 0, !items.isEmpty else { return items.isEmpty ? [] : [items] }
        return stride(from: 0, to: items.count, by: size).map {
            Array(items[$0..<min($0 + size, items.count)])
        }
    }
}
