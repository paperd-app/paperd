import Foundation
import Testing
import PaperdCore

@Suite("DoclingParser")
struct DoclingParserTests {
    @Test("texts/tablesのパースとページ順ソート")
    func parseAndSort() throws {
        let json = """
        {
          "schema_name": "DoclingDocument",
          "texts": [
            {"label": "title", "text": "A Great Paper", "prov": [{"page_no": 1, "bbox": {"t": 700}}]},
            {"label": "section_header", "text": "1. Introduction", "level": 1, "prov": [{"page_no": 1, "bbox": {"t": 600}}]},
            {"label": "text", "text": "Deep learning is great.", "prov": [{"page_no": 1, "bbox": {"t": 500}}]},
            {"label": "text", "text": "Second page text.", "prov": [{"page_no": 2, "bbox": {"t": 700}}]}
          ],
          "tables": [
            {"prov": [{"page_no": 1, "bbox": {"t": 300}}],
             "data": {"grid": [[{"text": "Model"}, {"text": "Score"}], [{"text": "Ours"}, {"text": "0.9"}]]}}
          ]
        }
        """
        let items = try DoclingParser.parse(data: Data(json.utf8))
        try #require(items.count == 5)
        #expect(items[0].kind == .title)
        #expect(items[1].kind == .sectionHeader(level: 1))
        #expect(items[2].text == "Deep learning is great.")
        #expect(items[3].kind == .table)
        #expect(items[3].text.contains("| Model | Score |"), Comment(rawValue: items[3].text))
        #expect(items[3].text.contains("|---|---|"))
        #expect(items[4].text == "Second page text.")
    }
}

@Suite("DoclingParserタイトル抽出")
struct TitleCandidateTests {
    @Test("titleラベルを優先")
    func prefersTitleLabel() {
        let items = [
            DoclingItem(kind: .sectionHeader(level: 1), text: "A long enough section header text", page: 1),
            DoclingItem(kind: .title, text: "Real Title"),
        ]
        #expect(DoclingParser.titleCandidate(items: items) == "Real Title")
    }

    @Test("titleなしは1ページ目の長い見出しへフォールバック")
    func fallsBackToFirstLongHeading() {
        // Doclingが論文タイトルをsection_headerとして出力するケース（実PDFで確認）
        let items = [
            DoclingItem(kind: .sectionHeader(level: 1), text: "Microscopic structure and migration of 90° ferroelectric domain wall", page: 1),
            DoclingItem(kind: .sectionHeader(level: 1), text: "ABSTRACT", page: 1),
            DoclingItem(kind: .paragraph, text: "Body.", page: 1),
        ]
        #expect(DoclingParser.titleCandidate(items: items)?.hasPrefix("Microscopic structure") == true)
    }

    @Test("短い見出し（ABSTRACT等）はタイトルにしない")
    func skipsShortHeadings() {
        let items = [
            DoclingItem(kind: .sectionHeader(level: 1), text: "ABSTRACT", page: 1),
            DoclingItem(kind: .paragraph, text: "Body.", page: 1),
        ]
        #expect(DoclingParser.titleCandidate(items: items) == nil)
    }

    @Test("2ページ目以降の見出しは対象外")
    func ignoresLaterPages() {
        let items = [
            DoclingItem(kind: .sectionHeader(level: 1), text: "A long enough heading on a later page", page: 3),
        ]
        #expect(DoclingParser.titleCandidate(items: items) == nil)
    }
}

@Suite("Chunker")
struct ChunkerTests {
    @Test("タイトル+アブストラクトチャンク")
    func titleAbstractPiece() {
        let piece = Chunker().titleAbstractPiece(title: "T", abstract: "Some abstract.")
        #expect(piece.sectionPath == "Title & Abstract")
        #expect(piece.text.contains("T") && piece.text.contains("Some abstract."))
    }

    @Test("セクション境界の尊重とsection_path")
    func sectionBoundaries() throws {
        let items = [
            DoclingItem(kind: .sectionHeader(level: 1), text: "3. Method"),
            DoclingItem(kind: .sectionHeader(level: 2), text: "3.2 Training"),
            DoclingItem(kind: .paragraph, text: "We train with Adam."),
            DoclingItem(kind: .sectionHeader(level: 1), text: "4. Results"),
            DoclingItem(kind: .paragraph, text: "We win."),
        ]
        let pieces = Chunker().chunk(items: items)
        try #require(pieces.count == 2)
        #expect(pieces[0].sectionPath == "3. Method > 3.2 Training")
        #expect(pieces[1].sectionPath == "4. Results")
    }

    @Test("参考文献・謝辞セクションの除外")
    func excludedSections() throws {
        let items = [
            DoclingItem(kind: .sectionHeader(level: 1), text: "1. Intro"),
            DoclingItem(kind: .paragraph, text: "Body text."),
            DoclingItem(kind: .sectionHeader(level: 1), text: "References"),
            DoclingItem(kind: .paragraph, text: "[1] Smith et al."),
            DoclingItem(kind: .sectionHeader(level: 1), text: "Acknowledgements"),
            DoclingItem(kind: .paragraph, text: "We thank everyone."),
        ]
        let pieces = Chunker().chunk(items: items)
        try #require(pieces.count == 1)
        #expect(pieces[0].text == "Body text.")
    }

    @Test("長いセクションの分割とオーバーラップ")
    func splittingAndOverlap() throws {
        let sentence = "This is a moderately long sentence about transformers and attention mechanisms. "
        let paragraphs = (0..<30).map { _ in DoclingItem(kind: .paragraph, text: String(repeating: sentence, count: 5)) }
        let items = [DoclingItem(kind: .sectionHeader(level: 1), text: "2. Background")] + paragraphs
        let chunker = Chunker(targetTokens: 512, overlapRatio: 0.15)
        let pieces = chunker.chunk(items: items)
        try #require(pieces.count > 1, "分割される (\(pieces.count))")
        for p in pieces {
            #expect(p.sectionPath == "2. Background")
            // 単一段落がtargetを超えるケースを除き、概ねtarget近辺に収まる
            #expect(p.tokenCount <= 512 + 70, "チャンクサイズ \(p.tokenCount)")
        }
        // オーバーラップ: 2番目のチャンク冒頭は1番目の末尾と重複する
        let firstTail = String(pieces[0].text.suffix(40))
        #expect(pieces[1].text.contains(firstTail.prefix(20)), "オーバーラップあり")
    }

    @Test("表は1チャンク、超過時のみ行分割（ヘッダ複製）")
    func tableChunking() throws {
        let smallTable = "| A | B |\n|---|---|\n| 1 | 2 |"
        let pieces = Chunker().chunk(items: [DoclingItem(kind: .table, text: smallTable)])
        try #require(pieces.count == 1)
        #expect(pieces[0].text == smallTable)

        let longRow = "| " + String(repeating: "data ", count: 50) + " | value |"
        let bigTable = (["| Col1 | Col2 |", "|---|---|"] + Array(repeating: longRow, count: 30)).joined(separator: "\n")
        let bigPieces = Chunker(targetTokens: 256).chunk(items: [DoclingItem(kind: .table, text: bigTable)])
        try #require(bigPieces.count > 1, "行分割される (\(bigPieces.count))")
        for p in bigPieces {
            #expect(p.text.hasPrefix("| Col1 | Col2 |\n|---|---|"), "ヘッダ複製: \(p.text.prefix(40))")
        }
    }

    @Test("ノートのチャンク化はNotesセクション")
    func noteChunking() throws {
        let pieces = Chunker().chunkNote("My note about this paper.")
        try #require(pieces.count == 1)
        #expect(pieces[0].sectionPath == "Notes")
    }

    @Test("トークン数の推定")
    func tokenEstimation() {
        #expect(Chunker.estimateTokens("hello world") >= 2)
        #expect(Chunker.estimateTokens("日本語のテキストです") >= 2, "CJKは文字数ベース")
    }
}

/// チャンクのハードキャップ（→ docs/06 2節。巨大数式チャンクでreindexが52分かかった事故の回帰テスト）
@Suite("チャンクのハードキャップ")
struct ChunkHardCapTests {
    @Test("巨大な1行LaTeX数式が強制分割される")
    func oversizedFormulaSplit() {
        let chunker = Chunker(targetTokens: 512)
        // 空白の多いLaTeX（単語数支配の見積りになる）を1ブロックで投入
        let formula = "$$ " + String(repeating: "\\phi _ { S } ( r ) = \\frac { 1 } { 2 } k r ^ { 2 } + ", count: 300) + " $$"
        let pieces = chunker.chunk(items: [
            DoclingItem(kind: .sectionHeader(level: 1), text: "Methods"),
            DoclingItem(kind: .formula, text: formula),
        ])
        #expect(pieces.count > 1, "分割される (\(pieces.count)個)")
        let cap = Int(Double(512) * 1.25)
        #expect(pieces.allSatisfy { $0.tokenCount <= cap },
                "全ピースがキャップ以下: 最大\(pieces.map(\.tokenCount).max() ?? 0)")
        // 内容は失われない（連結すれば元に戻る）
        #expect(pieces.map(\.text).joined() == formula)
        #expect(pieces.allSatisfy { $0.sectionPath == "Methods" })
    }

    @Test("通常サイズのチャンクは分割されない")
    func normalChunksUntouched() {
        let chunker = Chunker(targetTokens: 512)
        let pieces = chunker.chunk(items: [
            DoclingItem(kind: .paragraph, text: "Normal paragraph text."),
        ])
        #expect(pieces.count == 1)
    }
}
