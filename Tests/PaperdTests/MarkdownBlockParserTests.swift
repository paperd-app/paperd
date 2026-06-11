import Foundation
import Testing
import PaperdCore

@Suite("MarkdownBlockParser")
struct MarkdownBlockParserTests {
    @Test("見出しレベルの解釈")
    func headings() {
        let blocks = MarkdownBlockParser.parse("# Title\n\n## Section\n\n###### Deep")
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .heading(level: 2, text: "Section"),
            .heading(level: 6, text: "Deep"),
        ])
    }

    @Test("複数行の段落は1ブロックに結合")
    func paragraphJoining() {
        let blocks = MarkdownBlockParser.parse("line one\nline two\n\nsecond paragraph")
        #expect(blocks == [
            .paragraph("line one line two"),
            .paragraph("second paragraph"),
        ])
    }

    @Test("パイプテーブル: 区切り行スキップとセル解釈")
    func pipeTable() {
        let md = """
        | Model | Score |
        |---|:---:|
        | Ours | 0.92 |
        | Baseline | 0.81 |
        """
        let blocks = MarkdownBlockParser.parse(md)
        #expect(blocks == [
            .table(header: ["Model", "Score"], rows: [["Ours", "0.92"], ["Baseline", "0.81"]]),
        ])
    }

    @Test("テーブル内のエスケープされたパイプ")
    func escapedPipeInTable() {
        let md = "| A | B |\n|---|---|\n| x \\| y | z |"
        guard case .table(_, let rows)? = MarkdownBlockParser.parse(md).first else {
            Issue.record("テーブルとして解釈されない")
            return
        }
        #expect(rows == [["x | y", "z"]])
    }

    @Test("番号なし・番号つきリスト")
    func lists() {
        let blocks = MarkdownBlockParser.parse("- alpha\n- beta\n\n1. first\n2. second")
        #expect(blocks == [
            .list(items: ["alpha", "beta"], ordered: false),
            .list(items: ["first", "second"], ordered: true),
        ])
    }

    @Test("コードフェンス（言語タグ・閉じ忘れ）")
    func codeFences() {
        let blocks = MarkdownBlockParser.parse("```python\nprint(1)\n```\n\n```\nraw")
        #expect(blocks == [
            .codeBlock(language: "python", code: "print(1)"),
            .codeBlock(language: nil, code: "raw"),
        ])
    }

    @Test("imageプレースホルダと水平線")
    func placeholderAndRule() {
        let blocks = MarkdownBlockParser.parse("<!-- image -->\n\n---\n\ntext")
        #expect(blocks == [
            .imagePlaceholder,
            .horizontalRule,
            .paragraph("text"),
        ])
    }

    @Test("Docling出力の典型構造（実paper.md冒頭の再現）")
    func doclingTypicalOutput() {
        let md = """
        <!-- image -->

        ## Microscopic structure and migration of 90° ferroelectric domain wall

        Cite as: J. Appl. Phys. 133 , 104101 (2023)

        - Hikaru Azuma, Shuji Ogata, et al.

        ## ABSTRACT

        BaTiO3 is a well-known piezoelectric material. The formula is $P = \\alpha E$.
        """
        let blocks = MarkdownBlockParser.parse(md)
        #expect(blocks.count == 6)
        #expect(blocks[0] == .imagePlaceholder)
        #expect(blocks[1] == .heading(level: 2, text: "Microscopic structure and migration of 90° ferroelectric domain wall"))
        #expect(blocks[3] == .list(items: ["Hikaru Azuma, Shuji Ogata, et al."], ordered: false))
        guard case .paragraph(let text) = blocks[5] else {
            Issue.record("最終ブロックが段落でない: \(blocks[5])")
            return
        }
        #expect(text.contains("$P = \\alpha E$"), "数式はLaTeX文字列のまま保持")
    }

    @Test("テーブル直後の段落・段落直後のテーブル")
    func tableParagraphBoundaries() {
        let md = "before\n| A |\n|---|\n| 1 |\nafter"
        let blocks = MarkdownBlockParser.parse(md)
        #expect(blocks == [
            .paragraph("before"),
            .table(header: ["A"], rows: [["1"]]),
            .paragraph("after"),
        ])
    }
}
