import Foundation
import Testing
import PaperdCore

/// 各ステージを差し替え可能なフェイク実行器。
/// JobRunnerの並行tickから呼ばれるためミューテーションはロックで保護する
final class FakeExecutors: IngestStageExecutors, @unchecked Sendable {
    private let lock = NSLock()
    /// 呼び出し順の記録（"resolve" / "convert" / "embed"。スケジューリング検証用）
    var events: [String] = []
    var resolveResult: ResolvedMetadata
    var resolveCalls = 0
    var resolveIdentifiers: [PaperIdentifier] = []
    var resolveError: Error?
    /// convertが書き出すpaper.md / docling.jsonの差し替え（ローカルPDF解決テスト用）
    var convertMarkdownOverride: String?
    var convertDoclingOverride: String?
    var fetchSucceeds = true
    var fetchCalls = 0
    var convertCalls = 0
    var convertError: Error?
    var embedCalls = 0
    var embedError: Error?
    var bibliographicResult: ResolvedMetadata?
    var bibliographicCalls: [(title: String, author: String?)] = []
    var convertOptions: [WorkerClient.ConvertOptions] = []

    init(resolveResult: ResolvedMetadata) {
        self.resolveResult = resolveResult
    }

    struct TransientError: Error {}

    func resolveBibliographic(title: String, author: String?) async throws -> ResolvedMetadata? {
        bibliographicCalls.append((title, author))
        return bibliographicResult
    }

    func resolve(_ identifier: PaperIdentifier) async throws -> ResolvedMetadata {
        lock.lock()
        resolveCalls += 1
        resolveIdentifiers.append(identifier)
        events.append("resolve")
        let error = resolveError
        let result = resolveResult
        lock.unlock()
        if let error { throw error }
        return result
    }

    var fetchedPDFURLs: [String?] = []

    func fetchPDF(meta: ResolvedMetadata, destination: URL) async throws -> Bool {
        lock.lock()
        fetchCalls += 1
        fetchedPDFURLs.append(meta.pdfURL)
        let succeeds = fetchSucceeds
        lock.unlock()
        guard succeeds else { return false }
        try Data("%PDF-1.4 fake pdf \(meta.title)".utf8).write(to: destination)
        return true
    }

    func convert(pdfPath: URL, outputDir: URL, options: WorkerClient.ConvertOptions) async throws {
        lock.lock()
        convertCalls += 1
        convertOptions.append(options)
        events.append("convert")
        let error = convertError
        lock.unlock()
        if let error { throw error }
        let docling = """
        {"schema_name": "DoclingDocument",
         "texts": [
           {"label": "title", "text": "Attention Is All You Need", "prov": [{"page_no": 1, "bbox": {"t": 760}}]},
           {"label": "section_header", "text": "1. Introduction", "level": 1, "prov": [{"page_no": 1, "bbox": {"t": 700}}]},
           {"label": "text", "text": "We study transformer attention mechanisms in depth.", "prov": [{"page_no": 1, "bbox": {"t": 600}}]},
           {"label": "section_header", "text": "References", "level": 1, "prov": [{"page_no": 2, "bbox": {"t": 700}}]},
           {"label": "text", "text": "[1] Prior work.", "prov": [{"page_no": 2, "bbox": {"t": 600}}]}
         ]}
        """
        try Data((convertDoclingOverride ?? docling).utf8).write(to: outputDir.appendingPathComponent("paper.docling.json"))
        let markdown = convertMarkdownOverride ?? "# Paper\n\nWe study transformer attention."
        try Data(markdown.utf8).write(to: outputDir.appendingPathComponent("paper.md"))
    }

    var downloadedURLs: [URL] = []
    var downloadError: Error?

    func downloadFile(from url: URL, to destination: URL) async throws {
        lock.lock()
        downloadedURLs.append(url)
        let error = downloadError
        lock.unlock()
        if let error { throw error }
        try Data("%PDF-1.4 downloaded from \(url.absoluteString)".utf8).write(to: destination)
    }

    func embed(texts: [String]) async throws -> [[Float]] {
        lock.lock()
        embedCalls += 1
        events.append("embed")
        let error = embedError
        lock.unlock()
        if let error { throw error }
        return texts.map { FakeEmbedder.embed($0) }
    }
}

func sampleResolved() -> ResolvedMetadata {
    ResolvedMetadata(
        title: "Attention Is All You Need",
        abstract: "Abstract text.",
        year: 2017,
        venue: "NeurIPS",
        doi: "10.5555/3295222.3295349",
        arxivId: "1706.03762",
        arxivVersion: "v5",
        bibtexType: "inproceedings",
        booktitle: "NeurIPS",
        authors: [.init(displayName: "Ashish Vaswani")],
        pdfURL: "https://arxiv.org/pdf/1706.03762"
    )
}

@Suite("IngestPipeline")
struct IngestPipelineTests {
    func makePipeline() throws -> (LibraryStore, URL, JobQueue, FakeExecutors, IngestPipeline) {
        let (store, root) = try makeTempLibrary()
        let queue = JobQueue(db: store.db)
        let executors = FakeExecutors(resolveResult: sampleResolved())
        let pipeline = IngestPipeline(store: store, queue: queue, executors: executors)
        return (store, root, queue, executors, pipeline)
    }

    @Test("全ステージ成功でindexed")
    func fullPipelineSuccess() async throws {
        let (store, root, queue, _, pipeline) = try makePipeline()
        defer { cleanup(root) }
        let job = try queue.enqueue(kind: .ingest, payload: ["arxiv_id": "1706.03762"], origin: .app)
        let status = try await runToCompletion(queue, pipeline, job.id)
        #expect(status == .indexed)

        let finished = try #require(try queue.job(id: job.id))
        #expect(finished.jobStatus == .succeeded)
        #expect(finished.jobStage == .index)
        let paperId = try #require(finished.paperId)

        let paper = try #require(try store.paper(id: paperId))
        #expect(paper.paperStatus == .indexed)
        #expect(paper.pdfHash?.hasPrefix("sha256:") == true)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: store.layout.pdfPath(paperId).path), "paper.pdf")
        #expect(fm.fileExists(atPath: store.layout.markdownPath(paperId).path), "paper.md")
        #expect(fm.fileExists(atPath: store.layout.metaJSONPath(paperId).path), "meta.json")

        let counts = try store.db.read { db in
            (
                chunks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunks WHERE paper_id = ?", arguments: [paperId]) ?? 0,
                vec: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM vec_chunks") ?? 0
            )
        }
        // Title&Abstract + Introduction本文（Referencesは除外）
        #expect(counts.chunks == 2)
        #expect(counts.vec == 2)
    }

    @Test("PDF取得失敗はmetadata_onlyの部分的成功")
    func fetchFailurePartialSuccess() async throws {
        let (store, root, queue, executors, pipeline) = try makePipeline()
        defer { cleanup(root) }
        executors.fetchSucceeds = false
        let job = try queue.enqueue(kind: .ingest, payload: ["doi": "10.5555/3295222.3295349"], origin: .app)
        _ = try queue.claim(job.id)
        let status = try await pipeline.run(job: try #require(try queue.job(id: job.id)))
        #expect(status == .metadataOnly)
        #expect(try queue.job(id: job.id)?.jobStatus == .succeeded)
        let paperId = try #require(try queue.job(id: job.id)?.paperId)
        #expect(try store.paper(id: paperId)?.paperStatus == .metadataOnly)
    }

    @Test("一時的エラーでリトライ、再実行は失敗ステージから")
    func transientErrorAndResume() async throws {
        let (_, root, queue, executors, pipeline) = try makePipeline()
        defer { cleanup(root) }
        executors.convertError = FakeExecutors.TransientError()
        let job = try queue.enqueue(kind: .ingest, payload: ["arxiv_id": "1706.03762"], origin: .mcp)
        // 1回目: resolve+fetchで一旦キューへ戻る（resolve優先スケジューリング → docs/04 8節）
        _ = try queue.claim(job.id)
        _ = try await pipeline.run(job: try #require(try queue.job(id: job.id)))
        var current = try #require(try queue.job(id: job.id))
        #expect(current.jobStatus == .queued)
        #expect(current.jobStage == .fetch)
        #expect(current.retryCount == 0, "yieldはリトライではない")

        // 2回目（再開）: convertで一時的エラー
        _ = try queue.claim(job.id)
        let claimed = try #require(try queue.job(id: job.id))
        await #expect(throws: (any Error).self, "convertで失敗するはず") {
            _ = try await pipeline.run(job: claimed)
        }
        current = try #require(try queue.job(id: job.id))
        #expect(current.jobStatus == .queued, "バックオフ付きでqueuedへ")
        #expect(current.retryCount == 1)
        #expect(current.jobStage == .fetch, "fetchまで完了済み")
        #expect(executors.resolveCalls == 1)

        // 復旧して再実行 → resolve/fetchはスキップされconvertから
        executors.convertError = nil
        _ = try queue.claim(current.id)
        current = try #require(try queue.job(id: job.id))
        let status = try await pipeline.run(job: current)
        #expect(status == .indexed)
        #expect(executors.resolveCalls == 1, "resolveは再実行されない")
        #expect(executors.fetchCalls == 1, "fetchは再実行されない")
        #expect(executors.convertCalls == 2)
    }

    @Test("恒久的エラーで即failed")
    func permanentError() async throws {
        let (store, root, queue, executors, pipeline) = try makePipeline()
        defer { cleanup(root) }
        executors.convertError = IngestError.permanent("PDF_ENCRYPTED: PDF is password-protected")
        let job = try queue.enqueue(kind: .ingest, payload: ["arxiv_id": "1706.03762"], origin: .app)
        await #expect(throws: (any Error).self) {
            _ = try await runToCompletion(queue, pipeline, job.id)
        }
        let finished = try #require(try queue.job(id: job.id))
        #expect(finished.jobStatus == .failed)
        let paperId = try #require(finished.paperId)
        #expect(try store.paper(id: paperId)?.paperStatus == .failed)
    }

    @Test("DOI重複でcancelled")
    func duplicateDOI() async throws {
        let (store, root, queue, _, pipeline) = try makePipeline()
        defer { cleanup(root) }
        // 既存論文（同一DOI）
        try store.savePaper(samplePaper(), authors: [])
        let job = try queue.enqueue(kind: .ingest, payload: ["doi": "10.5555/3295222.3295349"], origin: .app)
        _ = try queue.claim(job.id)
        do {
            _ = try await pipeline.run(job: try #require(try queue.job(id: job.id)))
            Issue.record("duplicateエラーになるはず")
        } catch let error as IngestError {
            guard case .duplicate = error else {
                Issue.record("duplicate以外: \(error)")
                return
            }
        }
        #expect(try queue.job(id: job.id)?.jobStatus == .cancelled)
    }

    @Test("stub論文は同一行のまま昇格")
    func stubPromotion() async throws {
        let (store, root, queue, _, pipeline) = try makePipeline()
        defer { cleanup(root) }
        var stub = samplePaper()
        stub.isStub = true
        stub.paperStatus = .stub
        try store.savePaper(stub, authors: [])

        let job = try queue.enqueue(kind: .ingest, payload: ["doi": "10.5555/3295222.3295349"], origin: .app)
        let status = try await runToCompletion(queue, pipeline, job.id)
        #expect(status == .indexed)
        let promoted = try #require(try store.paper(id: stub.id), "同一paper_idのまま")
        #expect(!promoted.isStub, "is_stub解除")
        #expect(promoted.paperStatus == .indexed)
        // meta.jsonがファイル正本の対象になる（→ docs/08 4節）
        #expect(FileManager.default.fileExists(atPath: store.layout.metaJSONPath(stub.id).path))
    }

    @Test("JobRunner.tickがキューを駆動する")
    func jobRunnerTick() async throws {
        let (store, root, queue, _, pipeline) = try makePipeline()
        defer { cleanup(root) }
        _ = try queue.enqueue(kind: .ingest, payload: ["arxiv_id": "1706.03762"], origin: .mcp)
        let runner = JobRunner(queue: queue, pipeline: pipeline)
        let processed = await runner.tick()
        #expect(processed == 2, "resolve優先のyield + 再開で2回処理される")
        let papers = try store.allPapers()
        try #require(papers.count == 1)
        #expect(papers[0].paperStatus == .indexed)
    }
}
