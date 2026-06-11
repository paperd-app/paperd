import Foundation
import Testing
import PaperdCore

/// Crossref bibliographic検索のレコード選択（→ docs/04 4節）
@Suite("Crossref bibliographic検索")
struct BibliographicSearchTests {
    func fixture(items: [(doi: String, score: Double, type: String)]) -> String {
        let itemsJSON = items.map {
            #"{"DOI": "\#($0.doi)", "score": \#($0.score), "type": "\#($0.type)", "title": ["T"]}"#
        }.joined(separator: ",")
        return #"{"status": "ok", "message": {"items": [\#(itemsJSON)]}}"#
    }

    func search(_ items: [(doi: String, score: Double, type: String)]) async throws -> String? {
        let http = StubHTTPClient()
        http.add("api.crossref.org/works?", body: fixture(items: items))
        let client = CrossrefClient(http: http)
        return try await client.searchByBibliographic(title: "Some Paper Title", author: nil)
    }

    @Test("最上位がプレプリントで僅差に出版版がある場合は出版版を優先（SSRN実例の再現）")
    func prefersPublishedOverPreprint() async throws {
        // 実際に起きたケース: SSRN(60.4) > Acta Materialia(54.8)
        let doi = try await search([
            ("10.2139/ssrn.5162920", 60.4, "posted-content"),
            ("10.1016/j.actamat.2025.121216", 54.8, "journal-article"),
            ("10.1021/acsnano.7b07389.s001", 37.2, "component"),
        ])
        #expect(doi == "10.1016/j.actamat.2025.121216")
    }

    @Test("出版版が最上位ならそのまま採用")
    func topPublishedWins() async throws {
        let doi = try await search([
            ("10.1/journal", 80, "journal-article"),
            ("10.2/preprint", 75, "posted-content"),
        ])
        #expect(doi == "10.1/journal")
    }

    @Test("出版版が大差で劣る場合はプレプリントを採用（別論文の可能性）")
    func distantPublishedNotPreferred() async throws {
        let doi = try await search([
            ("10.2/preprint", 100, "posted-content"),
            ("10.1/journal", 50, "journal-article"),  // 100×0.8=80未満
        ])
        #expect(doi == "10.2/preprint")
    }

    @Test("出版版がなければプレプリントを採用")
    func preprintOnlyFallback() async throws {
        let doi = try await search([("10.2/preprint", 90, "posted-content")])
        #expect(doi == "10.2/preprint")
    }

    @Test("スコア閾値未満はnil")
    func belowThreshold() async throws {
        let doi = try await search([("10.1/weak", 30, "journal-article")])
        #expect(doi == nil)
    }
}

@Suite("stub吸収マージ")
struct StubAbsorptionTests {
    @Test("CitationStore.absorb: エッジ付け替えとstub行削除")
    func absorbReassignsEdges() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let citations = CitationStore(db: store.db)

        // center → stub のエッジを作る
        let center = samplePaper()
        try store.savePaper(center, authors: [])
        try citations.replaceEdges(
            center: center.id,
            references: [.init(title: "Target Paper", s2PaperId: "s2-target", doi: "10.1016/j.actamat.2025.121216")],
            citations: [], source: .s2)
        let stubId = try citations.upsertStub(.init(title: "Target Paper", doi: "10.1016/j.actamat.2025.121216"))

        // 取り込み行（ファイル持ち）に吸収
        let ingested = samplePaper(title: "Target Paper (ingested)", doi: "10.5/temp", arxivId: nil)
        try store.savePaper(ingested, authors: [])
        try citations.absorb(stubId: stubId, into: ingested.id)

        #expect(try store.paper(id: stubId) == nil, "stub行は削除")
        let network = try citations.egoNetwork(center: center.id)
        try #require(network.edges.count == 1)
        #expect(network.edges[0].citedId == ingested.id, "エッジが取り込み行を指す")
    }

    @Test("absorb: 両者間のエッジは自己参照にせず除去、既存エッジとの衝突はスキップ")
    func absorbHandlesConflicts() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let citations = CitationStore(db: store.db)
        let ingested = samplePaper()
        try store.savePaper(ingested, authors: [])
        let stubId = try citations.upsertStub(.init(title: "S", doi: "10.9/stub"))
        let other = try citations.upsertStub(.init(title: "O", doi: "10.9/other"))

        try store.db.write { dbc in
            // ingested → stub（吸収で自己参照になるため除去されるべき）
            try Citation(citingId: ingested.id, citedId: stubId, source: .s2).save(dbc)
            // stub → other と ingested → other（付け替えで衝突 → スキップされCASCADEで消える）
            try Citation(citingId: stubId, citedId: other, source: .s2).save(dbc)
            try Citation(citingId: ingested.id, citedId: other, source: .s2).save(dbc)
        }
        try citations.absorb(stubId: stubId, into: ingested.id)

        let edges = try store.db.read { try Citation.fetchAll($0) }
        #expect(edges.count == 1)
        #expect(edges[0].citingId == ingested.id && edges[0].citedId == other)
        #expect(!edges.contains { $0.citingId == $0.citedId }, "自己参照なし")
    }

    @Test("ローカルPDF解決がstubと同一DOIに確定 → stub吸収して同一論文1行に")
    func localPDFAbsorbsMatchingStub() async throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        let executors = FakeExecutors(resolveResult: sampleResolved())
        executors.bibliographicResult = sampleResolved()  // doi = 10.5555/3295222.3295349
        let pipeline = IngestPipeline(store: store, queue: queue, executors: executors)

        // 引用グラフ由来のstub（同じDOI）+ centerからのエッジ
        let center = samplePaper(title: "Center", doi: "10.1/center", arxivId: nil)
        try store.savePaper(center, authors: [])
        let citations = CitationStore(db: store.db)
        try citations.replaceEdges(
            center: center.id,
            references: [.init(title: "Attention Is All You Need", doi: "10.5555/3295222.3295349")],
            citations: [], source: .s2)
        let stubId = try store.db.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT id FROM papers WHERE doi = '10.5555/3295222.3295349'")!
        }

        // PDFドロップ取り込み
        let source = root.appendingPathComponent("drop.pdf")
        try Data("%PDF-1.4 content".utf8).write(to: source)
        let job = try queue.enqueue(kind: .ingest, payload: ["pdf_path": source.path], origin: .app)
        let status = try await runToCompletion(queue, pipeline, job.id)
        #expect(status == .indexed)

        let ingestedId = try #require(try queue.job(id: job.id)?.paperId)
        #expect(try store.paper(id: stubId) == nil, "stub行は吸収済み")
        let papers = try store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM papers WHERE doi = '10.5555/3295222.3295349'") }
        #expect(papers == 1, "同一DOIは1行")
        let network = try citations.egoNetwork(center: center.id)
        try #require(network.edges.count == 1)
        #expect(network.edges[0].citedId == ingestedId, "エッジが取り込み行へ付け替わる")
    }

    @Test("ローカルPDF解決がPDF取得済みの既存行と同一DOIに確定 → 重複cancelと後片付け")
    func localPDFDuplicateOfRealPaper() async throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        let executors = FakeExecutors(resolveResult: sampleResolved())
        executors.bibliographicResult = sampleResolved()
        let pipeline = IngestPipeline(store: store, queue: queue, executors: executors)

        // 既存の通常論文（同じDOI、**PDF取得済み**。PDF未取得なら合流になる → docs/04 4節）
        let existing = samplePaper()
        try store.savePaper(existing, authors: [])
        try FileManager.default.createDirectory(at: store.layout.paperDir(existing.id), withIntermediateDirectories: true)
        try Data("%PDF-1.4 existing".utf8).write(to: store.layout.pdfPath(existing.id))

        let source = root.appendingPathComponent("drop.pdf")
        try Data("%PDF-1.4 different content".utf8).write(to: source)
        let job = try queue.enqueue(kind: .ingest, payload: ["pdf_path": source.path], origin: .app)
        do {
            _ = try await runToCompletion(queue, pipeline, job.id)
            Issue.record("duplicateになるはず")
        } catch let error as IngestError {
            #expect(error == .duplicate(existingPaperId: existing.id))
        }
        #expect(try queue.job(id: job.id)?.jobStatus == .cancelled)
        // 作りかけの行とディレクトリが残っていない
        let count = try store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM papers") }
        #expect(count == 1)
    }
}
