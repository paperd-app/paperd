import Foundation
import Testing
import PaperdCore

@Suite("VectorStore")
struct VectorStoreTests {
    @Test("float32 BLOBのラウンドトリップ")
    func blobRoundtrip() {
        let vector: [Float] = [0.1, -0.5, 3.14, 0]
        let decoded = VectorStore.decode(VectorStore.encode(vector))
        #expect(decoded == vector)
    }

    @Test("コサイン類似度によるtop-k")
    func cosineTopK() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let paper = samplePaper()
        try store.savePaper(paper, authors: [])
        let index = SearchIndex(db: store.db)
        let pieces = [
            Chunker.Piece(sectionPath: "A", text: "attention transformer", tokenCount: 2),
            Chunker.Piece(sectionPath: "B", text: "image convolution", tokenCount: 2),
            Chunker.Piece(sectionPath: "C", text: "protein graph", tokenCount: 2),
        ]
        let ids = try index.indexPaper(paperId: paper.id, pieces: pieces, embeddings: pieces.map { FakeEmbedder.embed($0.text) })

        let query = FakeEmbedder.embed("attention is all you need transformer")
        let matches = try store.db.read { db in
            try VectorStore().topK(db, query: query, k: 2)
        }
        try #require(matches.count == 2)
        #expect(matches[0].chunkId == ids[0], "attentionチャンクが最上位")
        #expect(matches[0].score > matches[1].score)
    }
}

@Suite("RRF")
struct RRFTests {
    @Test("両リストに出るIDが最上位")
    func fusionRanking() throws {
        let fused = HybridSearch.rrf(rankings: [[1, 2, 3], [2, 4, 5]], k: 60)
        #expect(fused.first?.id == 2)
        // score(2) = 1/62 + 1/61
        let expected = 1.0 / 62 + 1.0 / 61
        let first = try #require(fused.first)
        #expect(abs(first.score - expected) < 1e-9)
    }

    @Test("FTSクエリのサニタイズ")
    func ftsQuerySanitization() {
        #expect(HybridSearch.sanitizeFTSQuery(#"attention AND "quoted""#) == #""attention" "AND" "quoted""#)
    }
}

@Suite("HybridSearch")
struct HybridSearchTests {
    /// attention論文（4チャンク）+ vision論文（1チャンク）の検索用ライブラリ
    func seedLibrary() throws -> (LibraryStore, URL, attention: Paper, vision: Paper) {
        let (store, root) = try makeTempLibrary()
        let attention = samplePaper()
        try store.savePaper(attention, authors: sampleAuthors)
        let vision = samplePaper(title: "Deep Residual Learning", doi: "10.1109/CVPR.2016.90", arxivId: "1512.03385", year: 2016, booktitle: "CVPR")
        try store.savePaper(vision, authors: [.init(displayName: "Kaiming He")])

        let index = SearchIndex(db: store.db)
        let attentionPieces = [
            Chunker.Piece(sectionPath: "Title & Abstract", text: "Attention Is All You Need. transformer attention", tokenCount: 8),
            Chunker.Piece(sectionPath: "3. Method", text: "scaled dot product attention transformer", tokenCount: 6),
            Chunker.Piece(sectionPath: "4. Results", text: "transformer outperforms recurrent baselines attention", tokenCount: 6),
            Chunker.Piece(sectionPath: "5. Discussion", text: "more attention discussion transformer", tokenCount: 5),
        ]
        try index.indexPaper(paperId: attention.id, pieces: attentionPieces,
                             embeddings: attentionPieces.map { FakeEmbedder.embed($0.text) })
        let visionPieces = [
            Chunker.Piece(sectionPath: "Title & Abstract", text: "Deep residual learning for image recognition convolution", tokenCount: 8),
        ]
        try index.indexPaper(paperId: vision.id, pieces: visionPieces,
                             embeddings: visionPieces.map { FakeEmbedder.embed($0.text) })
        return (store, root, attention, vision)
    }

    @Test("ハイブリッド検索: 関連論文が上位、match_type=hybrid")
    func hybridRanking() async throws {
        let (store, root, attention, _) = try seedLibrary()
        defer { cleanup(root) }
        let search = HybridSearch(db: store.db)
        let (results, semanticUsed) = try await search.search(query: "attention transformer", topK: 10, embedder: FakeEmbedder())
        #expect(semanticUsed)
        try #require(!results.isEmpty)
        #expect(results[0].paperId == attention.id)
        #expect(results[0].matchType == .hybrid)
    }

    @Test("論文ごとの最大チャンク数（既定3）でグルーピング")
    func perPaperChunkCap() async throws {
        let (store, root, attention, _) = try seedLibrary()
        defer { cleanup(root) }
        let search = HybridSearch(db: store.db)
        let (results, _) = try await search.search(query: "attention transformer", topK: 20, embedder: FakeEmbedder())
        let attentionHits = results.filter { $0.paperId == attention.id }
        #expect(attentionHits.count <= 3, "最大3チャンク (\(attentionHits.count))")
    }

    @Test("embedderなしはFTS5のみ（keyword）")
    func keywordOnly() async throws {
        let (store, root, _, vision) = try seedLibrary()
        defer { cleanup(root) }
        let search = HybridSearch(db: store.db)
        let (results, semanticUsed) = try await search.search(query: "residual", topK: 10, embedder: nil)
        #expect(!semanticUsed)
        try #require(results.count == 1)
        #expect(results[0].paperId == vision.id)
        #expect(results[0].matchType == .keyword)
    }

    @Test("embedder失敗時もFTS5にフォールバック")
    func embedderFailureFallback() async throws {
        let (store, root, _, _) = try seedLibrary()
        defer { cleanup(root) }
        let search = HybridSearch(db: store.db)
        let (results, semanticUsed) = try await search.search(query: "attention", topK: 10, embedder: FailingEmbedder())
        #expect(!semanticUsed)
        #expect(!results.isEmpty)
    }


    @Test("FTS構文エラーになり得るクエリも安全")
    func ftsSyntaxSafety() async throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let search = HybridSearch(db: store.db)
        _ = try await search.search(query: #"AND OR NOT ( ) * "broken"#, topK: 5, embedder: nil)
    }
}

@Suite("SearchIndex")
struct SearchIndexTests {
    @Test("embedding_metaの不一致検出")
    func embeddingMetaMismatch() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let index = SearchIndex(db: store.db)
        #expect(!(try index.needsReembedding(modelName: "BAAI/bge-m3", dimensions: 1024)), "メタ未記録時はfalse")
        try index.recordEmbeddingMeta(modelName: "BAAI/bge-m3", dimensions: 1024)
        #expect(!(try index.needsReembedding(modelName: "BAAI/bge-m3", dimensions: 1024)))
        #expect(try index.needsReembedding(modelName: "other-model", dimensions: 768))
    }

    @Test("チャンク差し替えで古い行が残らない")
    func chunkReplacement() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let paper = samplePaper()
        try store.savePaper(paper, authors: [])
        let index = SearchIndex(db: store.db)
        try index.indexPaper(paperId: paper.id, pieces: [
            Chunker.Piece(sectionPath: nil, text: "old text", tokenCount: 2),
            Chunker.Piece(sectionPath: nil, text: "old text 2", tokenCount: 3),
        ], embeddings: [[1, 0], [0, 1]])
        try index.indexPaper(paperId: paper.id, pieces: [
            Chunker.Piece(sectionPath: nil, text: "new text", tokenCount: 2),
        ], embeddings: [[1, 1]])
        let counts = try store.db.read { db in
            (
                chunks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunks") ?? -1,
                vec: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM vec_chunks") ?? -1,
                fts: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fts_chunks WHERE fts_chunks MATCH '\"old\"'") ?? -1
            )
        }
        #expect(counts.chunks == 1)
        #expect(counts.vec == 1)
        #expect(counts.fts == 0, "FTSから古いテキストが消えている")
    }
}
