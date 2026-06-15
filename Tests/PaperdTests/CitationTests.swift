import Foundation
import Testing
import PaperdCore

@Suite("CitationStore")
struct CitationStoreTests {
    @Test("stubのupsert: 外部IDで重複排除")
    func stubDeduplication() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let citations = CitationStore(db: store.db)

        let id1 = try citations.upsertStub(.init(title: "Cited Work", s2PaperId: "s2-abc", authors: ["Alice Smith"]))
        // 同じs2_paper_idは同一行（欠落フィールドは補完される）
        let id2 = try citations.upsertStub(.init(title: "Cited Work", year: 2015, s2PaperId: "s2-abc", doi: "10.1/cited"))
        #expect(id1 == id2)
        let paper = try #require(try store.paper(id: id1))
        #expect(paper.isStub)
        #expect(paper.year == 2015, "欠落フィールドの補完")
        #expect(paper.doi == "10.1/cited")
        // DOI経由でも同一行にヒット
        let id3 = try citations.upsertStub(.init(title: "Cited Work", doi: "10.1/cited"))
        #expect(id1 == id3)
    }

    @Test("非stub既存行（ライブラリ内論文）はそのまま再利用され上書きされない")
    func libraryPaperNotOverwritten() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let paper = samplePaper()
        try store.savePaper(paper, authors: sampleAuthors)

        let citations = CitationStore(db: store.db)
        let id = try citations.upsertStub(.init(title: "Different Title", year: 1999, doi: paper.doi))
        #expect(id == paper.id)
        let fetched = try #require(try store.paper(id: paper.id))
        #expect(fetched.title == paper.title, "ライブラリ正本は変更されない")
        #expect(fetched.year == 2017)
        #expect(!fetched.isStub)
    }

    @Test("replaceEdges: references/citationsの方向とエッジ差し替え")
    func replaceEdges() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let center = samplePaper()
        try store.savePaper(center, authors: [])
        let citations = CitationStore(db: store.db)

        try citations.replaceEdges(
            center: center.id,
            references: [.init(title: "Old Classic", s2PaperId: "s2-ref")],
            citations: [.init(title: "Follow-up", s2PaperId: "s2-cite")],
            source: .s2
        )
        let network = try citations.egoNetwork(center: center.id)
        #expect(network.nodes.count == 3)
        try #require(network.edges.count == 2)
        // center → reference（citing → cited）
        let refEdge = try #require(network.edges.first { $0.citingId == center.id })
        let refPaper = try #require(try store.paper(id: refEdge.citedId))
        #expect(refPaper.title == "Old Classic")
        // citation → center
        let citeEdge = try #require(network.edges.first { $0.citedId == center.id })
        let citePaper = try #require(try store.paper(id: citeEdge.citingId))
        #expect(citePaper.title == "Follow-up")

        // 再取得: 出方向（references）は差し替え、入方向（citations）は保持される
        try citations.replaceEdges(
            center: center.id,
            references: [.init(title: "New Reference", s2PaperId: "s2-ref2")],
            citations: [],
            source: .s2
        )
        let updated = try citations.egoNetwork(center: center.id)
        #expect(updated.edges.count == 2)
        #expect(!updated.edges.contains { $0.citingId == center.id && $0.citedId == refEdge.citedId }, "古い出エッジは消える")
        #expect(updated.edges.contains { $0.citedId == center.id }, "入エッジは保持")
    }

    @Test("TTL: エッジ未取得・期限切れはstale")
    func ttlStaleness() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let center = samplePaper()
        try store.savePaper(center, authors: [])
        let citations = CitationStore(db: store.db)

        #expect(try citations.isStale(paperId: center.id), "未取得はstale")

        try citations.replaceEdges(
            center: center.id,
            references: [.init(title: "R", s2PaperId: "s2-r")],
            citations: [], source: .s2)
        #expect(!(try citations.isStale(paperId: center.id)), "取得直後はfresh")
        // 31日後はstale（既定TTL30日 → docs/08 3節）
        let later = Date().addingTimeInterval(31 * 24 * 3600)
        #expect(try citations.isStale(paperId: center.id, now: later))
    }

    @Test("egoNetwork: 2ホップで隣接ノードのエッジも辿る")
    func twoHopNetwork() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let center = samplePaper()
        try store.savePaper(center, authors: [])
        let citations = CitationStore(db: store.db)

        try citations.replaceEdges(
            center: center.id,
            references: [.init(title: "Hop1", s2PaperId: "s2-hop1")],
            citations: [], source: .s2)
        let hop1Id = try citations.upsertStub(.init(title: "Hop1", s2PaperId: "s2-hop1"))
        try citations.replaceEdges(
            center: hop1Id,
            references: [.init(title: "Hop2", s2PaperId: "s2-hop2")],
            citations: [], source: .s2)

        let oneHop = try citations.egoNetwork(center: center.id, hops: 1)
        #expect(oneHop.nodes.count == 2)
        let twoHop = try citations.egoNetwork(center: center.id, hops: 2)
        #expect(twoHop.nodes.count == 3)
        #expect(twoHop.edges.count == 2)
    }

    @Test("citationLists: 参考文献と被引用を方向別に返す（→ docs/07 2.8節）")
    func citationLists() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let center = samplePaper()
        try store.savePaper(center, authors: sampleAuthors)
        let citations = CitationStore(db: store.db)
        try citations.replaceEdges(
            center: center.id,
            references: [.init(title: "Cited A", year: 2014), .init(title: "Cited B", year: 2010)],
            citations: [.init(title: "Citer X", year: 2019)],
            source: .s2)

        let lists = try citations.citationLists(of: center.id)
        #expect(Set(lists.references.map(\.title)) == ["Cited A", "Cited B"])
        #expect(lists.references.allSatisfy(\.isStub))
        #expect(lists.citations.map(\.title) == ["Citer X"])
        // 年の降順（年なしは末尾）
        #expect(lists.references.first?.title == "Cited A", "年の新しい順")

        // limitは各方向に効く
        let limited = try citations.citationLists(of: center.id, limit: 1)
        #expect(limited.references.count == 1)
    }
}

@Suite("CitationFetcher")
struct CitationFetcherTests {
    func s2EdgesFixture(key: String, papers: [(id: String, title: String)]) -> String {
        let items = papers.map { p in
            #"{"\#(key)": {"paperId": "\#(p.id)", "title": "\#(p.title)", "year": 2020, "citationCount": 5, "authors": []}}"#
        }.joined(separator: ",")
        return #"{"data": [\#(items)]}"#
    }

    @Test("refetch: S2からreferences/citationsを取得しstub+エッジを保存")
    func refetchStoresEdges() async throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let paper = samplePaper()
        try store.savePaper(paper, authors: [])

        let http = StubHTTPClient()
        http.add("/references", body: s2EdgesFixture(key: "citedPaper", papers: [("s2-r1", "Ref One"), ("s2-r2", "Ref Two")]))
        http.add("/citations", body: s2EdgesFixture(key: "citingPaper", papers: [("s2-c1", "Cite One")]))
        let fetcher = CitationFetcher(db: store.db, s2: SemanticScholarClient(http: http))

        try await fetcher.refetch(paperId: paper.id)

        let network = try CitationStore(db: store.db).egoNetwork(center: paper.id)
        #expect(network.nodes.count == 4)
        #expect(network.edges.filter { $0.citingId == paper.id }.count == 2, "references")
        #expect(network.edges.filter { $0.citedId == paper.id }.count == 1, "citations")
        #expect(network.edges.allSatisfy { $0.source == "s2" })
        // S2識別子はDOI:プレフィックス（s2PaperIdなしの場合 → docs/08 1節）
        #expect(http.requests[0].url.absoluteString.contains("DOI:"))
    }

    @Test("S2のdata:null（出版社によるreferences非公開）は空として扱う")
    func nullDataTreatedAsEmpty() async throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let paper = samplePaper()
        try store.savePaper(paper, authors: [])

        let http = StubHTTPClient()
        http.add("/references", body: #"{"data": null, "citingPaperInfo": {"note": "elided by the publisher"}}"#)
        http.add("/citations", body: s2EdgesFixture(key: "citingPaper", papers: [("s2-c1", "Cite One")]))
        let fetcher = CitationFetcher(db: store.db, s2: SemanticScholarClient(http: http))
        try await fetcher.refetch(paperId: paper.id)

        let network = try CitationStore(db: store.db).egoNetwork(center: paper.id)
        #expect(network.edges.count == 1, "citations側のみ保存される")
    }

    @Test("外部IDなしの論文は恒久的エラー")
    func noExternalIds() async throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        var paper = samplePaper(doi: nil, arxivId: nil)
        paper.s2PaperId = nil
        try store.savePaper(paper, authors: [])
        let fetcher = CitationFetcher(db: store.db, s2: SemanticScholarClient(http: StubHTTPClient()))
        await #expect(throws: IngestError.self) {
            try await fetcher.refetch(paperId: paper.id)
        }
    }

    @Test("JobRunner: refetch_citationsジョブのディスパッチとingest完了時の自動投入")
    func jobRunnerDispatch() async throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        let executors = FakeExecutors(resolveResult: sampleResolved())
        let pipeline = IngestPipeline(store: store, queue: queue, executors: executors)

        let http = StubHTTPClient()
        http.add("/references", body: s2EdgesFixture(key: "citedPaper", papers: [("s2-r1", "Ref One")]))
        http.add("/citations", body: s2EdgesFixture(key: "citingPaper", papers: []))
        let fetcher = CitationFetcher(db: store.db, s2: SemanticScholarClient(http: http))
        let runner = JobRunner(queue: queue, pipeline: pipeline, citationFetcher: fetcher)

        _ = try queue.enqueue(kind: .ingest, payload: ["arxiv_id": "1706.03762"], origin: .app)
        // tick: ingest（resolve優先のyield + 再開で2回）→ refetch_citations自動投入の計3件
        let processed = await runner.tick()
        #expect(processed == 3)

        let papers = try store.allPapers()
        try #require(papers.count == 1)
        let network = try CitationStore(db: store.db).egoNetwork(center: papers[0].id)
        #expect(network.edges.count == 1, "引用エッジが自動取得される")
        let allJobs = try queue.jobs()
        #expect(allJobs.count == 2)
        #expect(allJobs.allSatisfy { $0.jobStatus == .succeeded })
    }
}

@Suite("ForceLayout")
struct ForceLayoutTests {
    @Test("収束後の配置が有限・境界内・固定ノード不動")
    func layoutInvariants() {
        let nodes = (0..<20).map { "node-\($0)" }
        var edges: [(String, String)] = []
        for i in 1..<20 { edges.append(("node-0", "node-\(i)")) }
        var layout = ForceLayout(nodes: nodes, edges: edges, width: 800, height: 600, fixed: "node-0")
        let positions = layout.run(iterations: 100)

        #expect(positions.count == 20)
        for p in positions {
            #expect(p.x.isFinite && p.y.isFinite)
            #expect(p.x >= 0 && p.x <= 800)
            #expect(p.y >= 0 && p.y <= 600)
        }
        // 中心固定
        #expect(positions[0] == ForceLayout.Point(x: 400, y: 300))
    }

    @Test("接続ノードは非接続ノードより中心に近い")
    func connectedNodesCloser() {
        let nodes = ["center", "linked", "stranger"]
        var layout = ForceLayout(nodes: nodes, edges: [("center", "linked")], width: 800, height: 600, fixed: "center")
        let positions = layout.run(iterations: 300)
        func dist(_ a: ForceLayout.Point, _ b: ForceLayout.Point) -> Double {
            sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2))
        }
        let linkedDist = dist(positions[0], positions[1])
        let strangerDist = dist(positions[0], positions[2])
        #expect(linkedDist < strangerDist, "linked=\(linkedDist), stranger=\(strangerDist)")
    }

    @Test("決定的: 同じ入力は同じ配置")
    func deterministic() {
        let nodes = ["a", "b", "c", "d"]
        let edges = [("a", "b"), ("b", "c")]
        var l1 = ForceLayout(nodes: nodes, edges: edges)
        var l2 = ForceLayout(nodes: nodes, edges: edges)
        #expect(l1.run(iterations: 50) == l2.run(iterations: 50))
    }

    @Test("ノード半径は被引用数の対数スケール")
    func nodeRadius() {
        #expect(ForceLayout.nodeRadius(citationCount: 0) == 6)
        #expect(ForceLayout.nodeRadius(citationCount: 9) == 10)  // 6 + 4*log10(10)
        #expect(ForceLayout.nodeRadius(citationCount: 99999) < 30)
    }
}
