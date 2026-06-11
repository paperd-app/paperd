import Foundation
import Testing
import PaperdCore

/// UI整備に伴うコア追加分のテスト（→ docs/09 2.2節, docs/01 6節, docs/04 4節）
@Suite("paperd:// URLスキーム")
struct URLSchemeTests {
    func parse(_ s: String) -> URLSchemeRequest? {
        URL(string: s).flatMap(URLSchemeRequest.parse)
    }

    @Test("import: url / arxiv / doi")
    func importVariants() {
        #expect(parse("paperd://import?arxiv=1706.03762") == .importInput("1706.03762"))
        #expect(parse("paperd://import?doi=10.1038/nature14539") == .importInput("10.1038/nature14539"))
        #expect(parse("paperd://import?url=https%3A%2F%2Farxiv.org%2Fabs%2F1706.03762") == .importInput("https://arxiv.org/abs/1706.03762"))
        #expect(parse("paperd://import") == nil)
    }

    @Test("paper/<uuid>のディープリンクと不正URL")
    func deepLinkAndInvalid() {
        #expect(parse("paperd://paper/8f14e45f-1234") == .openPaper(id: "8f14e45f-1234"))
        #expect(parse("paperd://paper/") == nil)
        #expect(parse("https://example.com") == nil)
        #expect(parse("paperd://unknown") == nil)
    }
}

@Suite("手動解決")
struct ManualResolveTests {
    @Test("pdf_only論文にDOIを与えて解決し直すとindexedになる")
    func manualResolveByDOI() async throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        let executors = FakeExecutors(resolveResult: sampleResolved())
        let pipeline = IngestPipeline(store: store, queue: queue, executors: executors)

        // pdf_onlyの論文（書誌解決に失敗したドロップPDF）を作る
        executors.bibliographicResult = nil
        executors.convertDoclingOverride = #"{"texts": []}"#
        executors.convertMarkdownOverride = "body without identifiers"
        let source = root.appendingPathComponent("drop.pdf")
        try Data("%PDF-1.4 x".utf8).write(to: source)
        var job = try queue.enqueue(kind: .ingest, payload: ["pdf_path": source.path], origin: .app)
        _ = try await runToCompletion(queue, pipeline, job.id)
        let paperId = try #require(try queue.job(id: job.id)?.paperId)
        #expect(try store.paper(id: paperId)?.paperStatus == .pdfOnly)

        // 手動解決: DOIを指定してingestジョブを再投入（UIのresolveManually相当）
        job = try queue.enqueue(kind: .ingest, paperId: paperId, payload: ["doi": "10.5555/3295222.3295349"], origin: .app)
        let status = try await runToCompletion(queue, pipeline, job.id)
        #expect(status == .indexed)
        let resolved = try #require(try store.paper(id: paperId))
        #expect(resolved.doi == "10.5555/3295222.3295349")
        #expect(resolved.title == "Attention Is All You Need")
        #expect(resolved.paperStatus == .indexed)
    }

    @Test("手動解決のDOIが既存stubと一致 → stubを吸収して1行に")
    func manualResolveAbsorbsStub() async throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        let executors = FakeExecutors(resolveResult: sampleResolved())
        let pipeline = IngestPipeline(store: store, queue: queue, executors: executors)

        // pdf_only論文
        var pdfOnly = samplePaper(title: "Unresolved", doi: nil, arxivId: nil)
        pdfOnly.paperStatus = .pdfOnly
        try store.savePaper(pdfOnly, authors: [])
        try FileManager.default.createDirectory(at: store.layout.paperDir(pdfOnly.id), withIntermediateDirectories: true)
        try Data("%PDF-1.4 y".utf8).write(to: store.layout.pdfPath(pdfOnly.id))
        // 同じDOIのstub（引用グラフ由来）+ エッジ
        let center = samplePaper(title: "Center", doi: "10.1/center", arxivId: nil)
        try store.savePaper(center, authors: [])
        let citations = CitationStore(db: store.db)
        try citations.replaceEdges(
            center: center.id,
            references: [.init(title: "Attention Is All You Need", doi: "10.5555/3295222.3295349")],
            citations: [], source: .s2)

        let job = try queue.enqueue(kind: .ingest, paperId: pdfOnly.id, payload: ["doi": "10.5555/3295222.3295349"], origin: .app)
        let status = try await runToCompletion(queue, pipeline, job.id)
        #expect(status == .indexed)

        let count = try store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM papers WHERE doi = '10.5555/3295222.3295349'") }
        #expect(count == 1, "stubは吸収され1行")
        let network = try citations.egoNetwork(center: center.id)
        try #require(network.edges.count == 1)
        #expect(network.edges[0].citedId == pdfOnly.id, "エッジはpdf_only行（解決済み）を指す")
    }
}
