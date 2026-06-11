import Foundation
import Testing
import PaperdCore

@Suite("ローカルPDF取り込み")
struct LocalPDFTests {
    func makeSourcePDF(_ root: URL, name: String = "dropped.pdf") throws -> URL {
        let path = root.appendingPathComponent(name)
        try Data("%PDF-1.4 dropped pdf content".utf8).write(to: path)
        return path
    }

    func makePipeline() throws -> (LibraryStore, URL, JobQueue, FakeExecutors, IngestPipeline) {
        let (store, root) = try makeTempLibrary()
        let queue = JobQueue(db: store.db)
        let executors = FakeExecutors(resolveResult: sampleResolved())
        let pipeline = IngestPipeline(store: store, queue: queue, executors: executors)
        return (store, root, queue, executors, pipeline)
    }

    @Test("bibliographic解決成功: convert先行→DOI確定→indexed")
    func resolvedViaBibliographic() async throws {
        let (store, root, queue, executors, pipeline) = try makePipeline()
        defer { cleanup(root) }
        executors.bibliographicResult = sampleResolved()
        let source = try makeSourcePDF(root)

        let job = try queue.enqueue(kind: .ingest, payload: ["pdf_path": source.path], origin: .app)
        let status = try await runToCompletion(queue, pipeline, job.id)
        #expect(status == .indexed)

        let paperId = try #require(try queue.job(id: job.id)?.paperId)
        let paper = try #require(try store.paper(id: paperId))
        #expect(paper.title == "Attention Is All You Need", "bibliographic解決のメタデータが適用される")
        #expect(paper.doi == "10.5555/3295222.3295349")
        #expect(paper.paperStatus == .indexed)
        // FakeExecutorsのconvertはDocling JSONにtitleを含まないため、抽出にはフォールバックせず
        // ファイル名でなくDocling抽出タイトルが検索に使われたことを確認
        #expect(executors.bibliographicCalls.isEmpty == false)
        // convertは先行実行の1回のみ（convertステージはスキップ）
        #expect(executors.convertCalls == 1)
        // PDFがライブラリへコピーされている
        #expect(FileManager.default.fileExists(atPath: store.layout.pdfPath(paperId).path))
    }

    @Test("bibliographic解決失敗: pdf_onlyで完了、本文検索は機能")
    func unresolvedStaysPDFOnly() async throws {
        let (store, root, queue, executors, pipeline) = try makePipeline()
        defer { cleanup(root) }
        executors.bibliographicResult = nil
        let source = try makeSourcePDF(root)

        let job = try queue.enqueue(kind: .ingest, payload: ["pdf_path": source.path], origin: .app)
        let status = try await runToCompletion(queue, pipeline, job.id)
        #expect(status == .pdfOnly)

        let paperId = try #require(try queue.job(id: job.id)?.paperId)
        let paper = try #require(try store.paper(id: paperId))
        #expect(paper.paperStatus == .pdfOnly)
        #expect(try queue.job(id: job.id)?.jobStatus == .succeeded, "部分的成功")

        // 本文チャンクは索引化されている（タイトル+アブストラクトチャンクはpdf_onlyでは作らない → docs/06 2節）
        let chunks = try store.db.read { db in
            try String.fetchAll(db, sql: "SELECT COALESCE(section_path, '') FROM chunks WHERE paper_id = ?", arguments: [paperId])
        }
        #expect(!chunks.isEmpty)
        #expect(!chunks.contains("Title & Abstract"))

        let search = HybridSearch(db: store.db)
        let (results, _) = try await search.search(query: "transformer attention", topK: 5, embedder: nil)
        #expect(results.contains { $0.paperId == paperId }, "FTS5で本文ヒット")
    }

    @Test("pdf_hash一致で即duplicate")
    func duplicateByHash() async throws {
        let (store, root, queue, executors, pipeline) = try makePipeline()
        defer { cleanup(root) }
        executors.bibliographicResult = nil
        let source = try makeSourcePDF(root)

        let job1 = try queue.enqueue(kind: .ingest, payload: ["pdf_path": source.path], origin: .app)
        _ = try await runToCompletion(queue, pipeline, job1.id)
        let existingId = try #require(try queue.job(id: job1.id)?.paperId)

        // 同一内容のPDFを再ドロップ
        let source2 = try makeSourcePDF(root, name: "again.pdf")
        let job2 = try queue.enqueue(kind: .ingest, payload: ["pdf_path": source2.path], origin: .app)
        do {
            _ = try await runToCompletion(queue, pipeline, job2.id)
            Issue.record("duplicateになるはず")
        } catch let error as IngestError {
            #expect(error == .duplicate(existingPaperId: existingId))
        }
        #expect(try queue.job(id: job2.id)?.jobStatus == .cancelled)
    }
}
