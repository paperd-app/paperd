import Foundation
import Testing
import PaperdCore

/// お気に入り・自著フラグ（→ docs/02, docs/09 2.2節）
@Suite("お気に入り・自著フラグ")
struct PaperFlagsTests {
    @Test("setFavorite/setOwn: DBとmeta.jsonの両方に永続化される")
    func flagsPersist() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let paper = samplePaper()
        try store.savePaper(paper, authors: sampleAuthors)

        try store.setFavorite(paper.id, true)
        try store.setOwn(paper.id, true)

        let updated = try #require(try store.paper(id: paper.id))
        #expect(updated.isFavorite && updated.isOwn)
        let meta = try #require(try store.meta(of: paper.id))
        #expect(meta.isFavorite == true && meta.isOwn == true, "正本（meta.json）に保存")
        #expect(meta.authors.count == 2, "著者情報は保持される")

        try store.setFavorite(paper.id, false)
        #expect(try store.paper(id: paper.id)?.isFavorite == false)
        #expect(try store.paper(id: paper.id)?.isOwn == true, "他方のフラグは影響を受けない")
    }

    @Test("旧形式のmeta.json（フラグなし・collectionIdsあり）も読める")
    func backwardCompatibleDecoding() throws {
        let legacy = """
        {"formatVersion": 1, "id": "abc", "title": "Old Paper", "authors": [],
         "bibtexType": "misc", "status": "indexed", "collectionIds": ["c1"],
         "addedAt": "2025-01-01T00:00:00Z", "updatedAt": "2025-01-01T00:00:00Z"}
        """
        let meta = try PaperMeta.decode(from: Data(legacy.utf8))
        #expect(meta.title == "Old Paper")
        let paper = meta.toPaper()
        #expect(!paper.isFavorite && !paper.isOwn, "未指定はfalse")
    }
}

/// 自著被引用ネットワーク（→ docs/09 4.1節）
@Suite("自著被引用ネットワーク")
struct OwnNetworkTests {
    @Test("自著への入エッジでネットワークを構築、統計が正しい")
    func buildsNetworkAndStats() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let citations = CitationStore(db: store.db)

        // 自著2本
        let own1 = samplePaper(title: "My Paper 1", doi: "10.1000/own1", arxivId: nil)
        let own2 = samplePaper(title: "My Paper 2", doi: "10.1000/own2", arxivId: nil)
        try store.savePaper(own1, authors: [])
        try store.savePaper(own2, authors: [])
        try store.setOwn(own1.id, true)
        try store.setOwn(own2.id, true)
        // 無関係な論文（ネットワークに出ない）
        let other = samplePaper(title: "Other", doi: "10.1000/other", arxivId: nil)
        try store.savePaper(other, authors: [])

        // own1へ外部から2件、own2へ1件（うち1論文は両方を引用）、own2 → own1 の自著間引用
        try citations.addEdges(center: own1.id, references: [], citations: [
            .init(title: "Citer A", doi: "10.1000/ca"),
            .init(title: "Citer B", doi: "10.1000/cb"),
        ], source: .s2)
        try citations.addEdges(center: own2.id, references: [], citations: [
            .init(title: "Citer A", doi: "10.1000/ca"),
        ], source: .s2)
        try store.db.write { dbc in
            try Citation(citingId: own2.id, citedId: own1.id, source: .s2).save(dbc)
        }

        let network = try citations.ownCitationNetwork()
        #expect(network.ownIds == [own1.id, own2.id])
        #expect(network.incomingCitationCount == 3, "外部からの被引用（自著間は除外）")
        #expect(network.uniqueCiterCount == 2, "Citer A/Bの2論文")
        #expect(network.citationCount(of: own1.id) == 3, "own1: 外部2 + own2から1")
        #expect(network.edges.contains { $0.citingId == own2.id && $0.citedId == own1.id }, "自著間エッジも含む")
        #expect(!network.nodes.contains { $0.id == other.id }, "無関係な論文は含まない")
    }

    @Test("自著未登録なら空ネットワーク")
    func emptyWhenNoOwnPapers() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        try store.savePaper(samplePaper(), authors: [])
        let network = try CitationStore(db: store.db).ownCitationNetwork()
        #expect(network.ownIds.isEmpty && network.nodes.isEmpty && network.edges.isEmpty)
    }

    @Test("ForceLayout.isConverged: 反復で収束する")
    func layoutConvergence() {
        var layout = ForceLayout(nodes: ["a", "b", "c"], edges: [("a", "b")])
        #expect(!layout.isConverged)
        _ = layout.run(iterations: 300)
        #expect(layout.isConverged)
    }
}
