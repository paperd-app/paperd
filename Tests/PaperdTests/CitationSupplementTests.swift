import Foundation
import Testing
import PaperdCore

/// OpenAlexによる引用補完マージ（→ docs/08 1節）
@Suite("OpenAlex引用補完")
struct CitationSupplementTests {
    func oaWork(id: String, title: String, doi: String? = nil, refs: [String] = []) -> String {
        let doiPart = doi.map { #""doi": "https://doi.org/\#($0)","# } ?? ""
        let refsPart = refs.map { #""https://openalex.org/\#($0)""# }.joined(separator: ",")
        return """
        {"id": "https://openalex.org/\(id)", "display_name": "\(title)", \(doiPart)
         "publication_year": 2024,
         "primary_location": {"source": {"display_name": "Some Journal"}},
         "referenced_works": [\(refsPart)]}
        """
    }

    @Test("citingWorks: cites:フィルタのページング取得")
    func citingWorksParsing() async throws {
        let http = StubHTTPClient()
        http.add("filter=cites:W1", body: #"{"results": [\#(oaWork(id: "W10", title: "Citer A", doi: "10.1000/a")), \#(oaWork(id: "W11", title: "Citer B"))]}"#)
        let client = OpenAlexClient(http: http)
        let works = try await client.citingWorks(openalexId: "W1")
        try #require(works.count == 2)
        #expect(works[0].openalexId == "W10")
        #expect(works[0].doi == "10.1000/a")
        #expect(works[0].venue == "Some Journal")
    }

    @Test("work(openalexId:): referenced_worksの取得")
    func referencedWorksParsing() async throws {
        let http = StubHTTPClient()
        http.add("/works/W1", body: oaWork(id: "W1", title: "Center", refs: ["W20", "W21"]))
        let client = OpenAlexClient(http: http)
        let work = try await client.work(openalexId: "W1")
        #expect(work.referencedWorkIds == ["W20", "W21"])
    }

    @Test("works(ids:): バッチ取得")
    func batchWorks() async throws {
        let http = StubHTTPClient()
        http.add("filter=openalex:W20%7CW21", body: #"{"results": [\#(oaWork(id: "W20", title: "Ref A")), \#(oaWork(id: "W21", title: "Ref B"))]}"#)
        let client = OpenAlexClient(http: http)
        let works = try await client.works(ids: ["W20", "W21"])
        #expect(works.map(\.openalexId) == ["W20", "W21"])
    }

    @Test("addEdges: 既存エッジを上書きせず（source保持）、openalex_idで重複排除")
    func addEdgesMergeRules() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let center = samplePaper()
        try store.savePaper(center, authors: [])
        let citations = CitationStore(db: store.db)

        // S2由来の被引用（DOIつき）
        try citations.replaceEdges(center: center.id, references: [],
            citations: [.init(title: "Shared Citer", s2PaperId: "s2-x", doi: "10.1000/shared")], source: .s2)
        // OpenAlex補完: 同一論文（DOI一致）+ 新規（OpenAlexのみ）
        try citations.addEdges(center: center.id, references: [],
            citations: [
                .init(title: "Shared Citer", doi: "10.1000/shared", openalexId: "W100"),
                .init(title: "OA Only Citer", openalexId: "W101"),
            ], source: .openalex)

        let network = citations
        let edges = try store.db.read { try Citation.fetchAll($0) }
        #expect(edges.count == 2, "DOI一致分は重複しない")
        let shared = try #require(edges.first { e in
            (try? store.paper(id: e.citingId))??.doi == "10.1000/shared"
        })
        #expect(shared.source == "s2", "既存エッジのsourceは保持")
        // 共有stubにopenalex_idが補完されている
        let sharedStub = try #require(try store.paper(id: shared.citingId))
        #expect(sharedStub.openalexId == "W100")
        _ = network
    }

    @Test("refetch: S2とOpenAlexの統合（S2 4件 + OA 9件・一部重複 → 統合）")
    func fetcherMergesBothSources() async throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        var paper = samplePaper()
        paper.openalexId = "W1"
        try store.savePaper(paper, authors: [])

        let http = StubHTTPClient()
        // S2: references非公開（data:null）+ citations 2件
        http.add("/references", body: #"{"data": null}"#)
        http.add("/citations", body: """
            {"data": [
              {"citingPaper": {"paperId": "s2-c1", "title": "Citer One", "externalIds": {"DOI": "10.1000/c1"}, "authors": []}},
              {"citingPaper": {"paperId": "s2-c2", "title": "Citer Two", "authors": []}}
            ]}
            """)
        // OpenAlex: 被引用3件（1件はS2とDOI重複）+ referenced_works 2件
        http.add("filter=cites:W1", body: #"{"results": [\#(oaWork(id: "W10", title: "Citer One", doi: "10.1000/c1")), \#(oaWork(id: "W11", title: "Citer Three", doi: "10.1000/c3")), \#(oaWork(id: "W12", title: "Citer Four"))]}"#)
        http.add("/works/W1", body: oaWork(id: "W1", title: "Center", refs: ["W20", "W21"]))
        http.add("filter=openalex:W20%7CW21", body: #"{"results": [\#(oaWork(id: "W20", title: "Ref A", doi: "10.1000/r1")), \#(oaWork(id: "W21", title: "Ref B"))]}"#)

        let fetcher = CitationFetcher(
            db: store.db,
            s2: SemanticScholarClient(http: http),
            openAlex: OpenAlexClient(http: http))
        try await fetcher.refetch(paperId: paper.id)

        let network = try CitationStore(db: store.db).egoNetwork(center: paper.id)
        let citing = network.edges.filter { $0.citedId == paper.id }
        let refs = network.edges.filter { $0.citingId == paper.id }
        #expect(citing.count == 4, "S2の2件 + OAの3件 - DOI重複1件 = 4件")
        #expect(refs.count == 2, "S2非公開でもOpenAlexのreferenced_worksで取得")
        #expect(refs.allSatisfy { $0.source == "openalex" })
    }

    @Test("refetch: S2が完全に失敗してもOpenAlexだけで成立する")
    func fetcherSurvivesS2Failure() async throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        var paper = samplePaper()
        paper.openalexId = "W1"
        try store.savePaper(paper, authors: [])

        let http = StubHTTPClient()
        http.add("api.semanticscholar.org", status: 429, body: "")  // レートリミット
        http.add("filter=cites:W1", body: #"{"results": [\#(oaWork(id: "W10", title: "Citer", doi: "10.1000/c"))]}"#)
        http.add("/works/W1", body: oaWork(id: "W1", title: "Center"))

        let fetcher = CitationFetcher(
            db: store.db,
            s2: SemanticScholarClient(http: http),
            openAlex: OpenAlexClient(http: http))
        try await fetcher.refetch(paperId: paper.id)

        let network = try CitationStore(db: store.db).egoNetwork(center: paper.id)
        #expect(network.edges.count == 1)
        #expect(network.edges[0].source == "openalex")
    }

    @Test("refetch: 両ソースとも失敗ならエラー（リトライ対象）")
    func fetcherFailsWhenBothFail() async throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        var paper = samplePaper()
        paper.openalexId = "W1"
        try store.savePaper(paper, authors: [])
        let http = StubHTTPClient()  // 全ルート404
        let fetcher = CitationFetcher(
            db: store.db,
            s2: SemanticScholarClient(http: http),
            openAlex: OpenAlexClient(http: http))
        await #expect(throws: (any Error).self) {
            try await fetcher.refetch(paperId: paper.id)
        }
    }
}

/// 関係フィルタと色分け（→ docs/08 5節・6節）
@Suite("引用グラフの関係フィルタ")
struct CitationRelationFilterTests {
    /// center → ref1 → ref2（参考文献の連鎖）と citer1 → center、citer2 → citer1（被引用の連鎖）
    func makeNetwork() -> CitationStore.EgoNetwork {
        func paper(_ id: String) -> Paper {
            Paper(id: id, title: id, status: .stub, isStub: true)
        }
        return CitationStore.EgoNetwork(
            center: "center",
            nodes: ["center", "ref1", "ref2", "citer1", "citer2"].map(paper),
            edges: [
                Citation(citingId: "center", citedId: "ref1", source: .s2),
                Citation(citingId: "ref1", citedId: "ref2", source: .s2),
                Citation(citingId: "citer1", citedId: "center", source: .s2),
                Citation(citingId: "citer2", citedId: "citer1", source: .s2),
            ]
        )
    }

    @Test("referencesフィルタ: 引用方向に到達可能な部分グラフのみ（2ホップ一貫）")
    func referencesFilter() {
        let filtered = makeNetwork().filtered(.references)
        #expect(Set(filtered.nodes.map(\.id)) == ["center", "ref1", "ref2"])
        #expect(filtered.edges.count == 2)
        #expect(!filtered.edges.contains { $0.citedId == "center" }, "被引用エッジは出ない")
    }

    @Test("citationsフィルタ: 逆方向に到達可能な部分グラフのみ")
    func citationsFilter() {
        let filtered = makeNetwork().filtered(.citations)
        #expect(Set(filtered.nodes.map(\.id)) == ["center", "citer1", "citer2"])
        #expect(filtered.edges.count == 2)
        #expect(!filtered.edges.contains { $0.citingId == "center" }, "参考文献エッジは出ない")
    }

    @Test("allフィルタは全体をそのまま返す")
    func allFilter() {
        let network = makeNetwork()
        #expect(network.filtered(.all) == network)
    }

    @Test("nodeRelation: 中心との直接関係の分類")
    func nodeRelationClassification() {
        var network = makeNetwork()
        // 相互引用を追加: center ⇄ mutual
        network.nodes.append(Paper(id: "mutual", title: "mutual", status: .stub, isStub: true))
        network.edges.append(Citation(citingId: "center", citedId: "mutual", source: .s2))
        network.edges.append(Citation(citingId: "mutual", citedId: "center", source: .s2))

        guard case .center = network.nodeRelation(of: "center") else { Issue.record("center"); return }
        guard case .reference = network.nodeRelation(of: "ref1") else { Issue.record("ref1"); return }
        guard case .citer = network.nodeRelation(of: "citer1") else { Issue.record("citer1"); return }
        guard case .both = network.nodeRelation(of: "mutual") else { Issue.record("mutual"); return }
        guard case .indirect = network.nodeRelation(of: "ref2") else { Issue.record("ref2"); return }
    }
}

/// ハブ論文の表示上限（→ docs/08 6節。フリーズバグの回帰テスト）
@Suite("エゴネットワークの表示上限")
struct EgoNetworkLimitTests {
    /// 次数の大きいハブを持つネットワークを作る
    func makeHub(_ store: LibraryStore, citers: Int) throws -> Paper {
        let hub = samplePaper(title: "Hub Classic", doi: "10.1000/hub", arxivId: nil)
        try store.savePaper(hub, authors: [])
        let citations = CitationStore(db: store.db)
        let stubs = (0..<citers).map { i in
            CitationStore.StubInfo(title: "Citer \(i)", doi: "10.1000/citer\(i)")
        }
        try citations.addEdges(center: hub.id, references: [], citations: stubs, source: .s2)
        return hub
    }

    @Test("1ホップ上限: 超過分は間引かれ省略数が記録される")
    func firstHopLimit() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let hub = try makeHub(store, citers: 200)
        let network = try CitationStore(db: store.db).egoNetwork(center: hub.id, firstHopLimit: 150)
        #expect(network.edges.count == 150)
        #expect(network.nodes.count == 151)
        #expect(network.omittedEdgeCounts[hub.id] == 50, "+50件省略")
    }

    @Test("2ホップの全体ノード上限で展開が打ち切られる")
    func maxNodesCap() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let hub = try makeHub(store, citers: 100)
        // 各citerにさらに10本ずつ参照を生やす（無制限なら100×10=1000ノード超）
        let citations = CitationStore(db: store.db)
        let citerIds = try store.db.read { dbc in
            try String.fetchAll(dbc, sql: "SELECT citing_id FROM citations WHERE cited_id = ?", arguments: [hub.id])
        }
        for (i, citerId) in citerIds.enumerated() {
            let refs = (0..<10).map { CitationStore.StubInfo(title: "Ref \(i)-\($0)", doi: "10.1000/r\(i)x\($0)") }
            try citations.addEdges(center: citerId, references: refs, citations: [], source: .s2)
        }
        let network = try citations.egoNetwork(center: hub.id, hops: 2, maxNodes: 400)
        #expect(network.nodes.count <= 400, "全体上限でキャップ (\(network.nodes.count))")
        // エッジの両端は必ず採用ノード
        let ids = Set(network.nodes.map(\.id))
        #expect(network.edges.allSatisfy { ids.contains($0.citingId) && ids.contains($0.citedId) })
    }

    @Test("自著ネットワーク: 描画は上限つきでも統計は真値")
    func ownNetworkTrueStats() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let own = samplePaper(title: "My Hub", doi: "10.1000/own", arxivId: nil)
        try store.savePaper(own, authors: [])
        try store.setOwn(own.id, true)
        let citations = CitationStore(db: store.db)
        let stubs = (0..<450).map { CitationStore.StubInfo(title: "C\($0)", doi: "10.1000/c\($0)") }
        try citations.addEdges(center: own.id, references: [], citations: stubs, source: .s2)

        let network = try citations.ownCitationNetwork()
        #expect(network.edges.count == 400, "描画エッジは上限400")
        #expect(network.incomingCitationCount == 450, "統計ヘッダは真値")
        #expect(network.uniqueCiterCount == 450)
    }
}
