import Foundation
import PaperdCore

/// テスト用一時ライブラリ
func makeTempLibrary() throws -> (LibraryStore, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("paperd-tests-\(UUID().uuidString)")
    let store = try LibraryStore.create(at: root)
    return (store, root)
}

func cleanup(_ root: URL) {
    try? FileManager.default.removeItem(at: root)
}

/// 決定的なフェイクembedder: 既知語彙の出現で次元が立つ単純なBoW
struct FakeEmbedder: QueryEmbedder, Sendable {
    static let vocabulary = [
        "attention", "transformer", "convolution", "image", "reinforcement",
        "language", "graph", "protein", "diffusion", "retrieval",
    ]

    static func embed(_ text: String) -> [Float] {
        let lower = text.lowercased()
        var vector = vocabulary.map { lower.contains($0) ? Float(1) : Float(0) }
        // ゼロベクトル回避
        if vector.allSatisfy({ $0 == 0 }) { vector[vector.count - 1] = 0.001 }
        return vector
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        Self.embed(text)
    }
}

/// 常に失敗するembedder（ワーカー未起動の再現）
struct FailingEmbedder: QueryEmbedder, Sendable {
    struct Unavailable: Error {}
    func embedQuery(_ text: String) async throws -> [Float] {
        throw Unavailable()
    }
}

/// 固定レスポンスを返すスタブHTTPクライアント
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    /// URL部分一致 → レスポンス
    var routes: [(pattern: String, response: HTTPResponse)] = []
    private(set) var requests: [HTTPRequest] = []
    private let queue = DispatchQueue(label: "stub-http")

    func add(_ pattern: String, status: Int = 200, body: String) {
        routes.append((pattern, HTTPResponse(statusCode: status, body: Data(body.utf8))))
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        queue.sync { requests.append(request) }
        let url = request.url.absoluteString
        for route in routes where url.contains(route.pattern) {
            return route.response
        }
        return HTTPResponse(statusCode: 404, body: Data())
    }
}

/// テストで使う標準的な論文行
func samplePaper(
    title: String = "Attention Is All You Need",
    doi: String? = "10.5555/3295222.3295349",
    arxivId: String? = "1706.03762",
    year: Int? = 2017,
    booktitle: String? = "Advances in Neural Information Processing Systems"
) -> Paper {
    Paper(
        title: title,
        abstract: "The dominant sequence transduction models are based on attention.",
        year: year,
        venue: "NeurIPS",
        doi: doi,
        arxivId: arxivId,
        bibtexType: booktitle != nil ? "inproceedings" : "misc",
        booktitle: booktitle,
        url: "https://arxiv.org/abs/1706.03762",
        status: .metadataOnly
    )
}

let sampleAuthors: [PaperMeta.AuthorEntry] = [
    .init(displayName: "Ashish Vaswani", s2AuthorId: "1738948"),
    .init(displayName: "Noam Shazeer"),
]

/// ジョブを完走させる（resolve優先スケジューリングのyieldを跨いで実行 → docs/04 8節）。
/// 重複等のエラーはそのままthrowされる
@discardableResult
func runToCompletion(_ queue: JobQueue, _ pipeline: IngestPipeline, _ jobId: String, maxRounds: Int = 6) async throws -> PaperStatus {
    var last: PaperStatus = .metadataOnly
    for _ in 0..<maxRounds {
        guard let job = try queue.job(id: jobId), job.jobStatus == .queued else { break }
        _ = try queue.claim(jobId)
        guard let claimed = try queue.job(id: jobId) else { break }
        last = try await pipeline.run(job: claimed)
    }
    return last
}
