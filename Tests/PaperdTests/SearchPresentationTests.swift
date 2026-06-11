import Foundation
import Testing
import PaperdCore

@Suite("検索ヒット強度と一致箇所")
struct SearchPresentationTests {
    @Test("termRanges: クエリ語の出現範囲（大文字小文字無視・マージ済み）")
    func termRangesBasics() {
        let text = "Scaled dot-product Attention computes attention weights for the transformer."
        let ranges = SearchPresentation.termRanges(query: "attention transformer", in: text)
        let found = ranges.map { String(text[$0]).lowercased() }
        #expect(found == ["attention", "attention", "transformer"])
    }

    @Test("termRanges: 1文字語・記号は無視、ヒットなしは空")
    func termRangesEdgeCases() {
        #expect(SearchPresentation.termRanges(query: "a ( )", in: "abc").isEmpty)
        #expect(SearchPresentation.termRanges(query: "missing", in: "nothing here").isEmpty)
    }

    @Test("termRanges: 重なる範囲はマージされる")
    func overlappingRangesMerged() {
        // "transform" と "transformer" が同一箇所で重なる
        let text = "the transformer model"
        let ranges = SearchPresentation.termRanges(query: "transform transformer", in: text)
        #expect(ranges.count == 1)
        #expect(String(text[ranges[0]]) == "transformer")
    }

    @Test("blockIndex: section_path末尾の見出しを正規化一致で特定")
    func blockIndexForSectionPath() {
        let blocks = MarkdownBlockParser.parse("""
        ## 1. Introduction

        intro text

        ## 3. Method

        ### 3.2 Training

        body
        """)
        #expect(MarkdownBlockParser.blockIndex(forSectionPath: "3. Method > 3.2 Training", in: blocks) == 3)
        #expect(MarkdownBlockParser.blockIndex(forSectionPath: "1. Introduction", in: blocks) == 0)
        #expect(MarkdownBlockParser.blockIndex(forSectionPath: "Title & Abstract", in: blocks) == nil)
    }

    @Test("HybridSearch: semanticScore（コサイン）とkeywordRankが付与される")
    func strengthFieldsPopulated() async throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let paper = samplePaper()
        try store.savePaper(paper, authors: [])
        let pieces = [
            Chunker.Piece(sectionPath: "A", text: "attention transformer text", tokenCount: 3),
            Chunker.Piece(sectionPath: "B", text: "image convolution text", tokenCount: 3),
        ]
        try SearchIndex(db: store.db).indexPaper(
            paperId: paper.id, pieces: pieces,
            embeddings: pieces.map { FakeEmbedder.embed($0.text) })

        let search = HybridSearch(db: store.db)
        let (results, _) = try await search.search(query: "attention transformer", topK: 5, embedder: FakeEmbedder())
        let top = try #require(results.first)
        #expect(top.matchType == .hybrid)
        #expect(top.chunkId > 0, "チャンクIDで行を一意に識別できる")
        #expect(Set(results.map(\.chunkId)).count == results.count, "chunkIdは結果内で一意")
        let semantic = try #require(top.semanticScore)
        #expect(semantic > 0 && semantic <= 1.0, "コサイン類似度は0〜1")
        #expect(top.keywordRank == 1, "FTS最上位")

        // keywordのみのクエリ（embedderなし）: semanticScoreはnil
        let (keywordResults, _) = try await search.search(query: "convolution", topK: 5, embedder: nil)
        let keywordTop = try #require(keywordResults.first)
        #expect(keywordTop.semanticScore == nil)
        #expect(keywordTop.keywordRank == 1)
    }
}
