import Foundation
import Testing
import PaperdCore

@Suite("BibtexGenerator")
struct BibtexTests {
    @Test("citation key生成規則: vaswani2017attention")
    func citationKeyBasic() {
        let key = BibtexGenerator.citationKey(
            title: "Attention Is All You Need",
            firstAuthor: "Ashish Vaswani",
            year: 2017
        )
        #expect(key == "vaswani2017attention")
    }

    @Test("citation key: ストップワードのスキップ")
    func citationKeyStopWords() {
        let key = BibtexGenerator.citationKey(
            title: "On the Properties of Neural Machine Translation",
            firstAuthor: "Kyunghyun Cho",
            year: 2014
        )
        #expect(key == "cho2014properties")
    }

    @Test("citation key: 非ASCII姓のfold")
    func citationKeyAsciiFold() {
        let key = BibtexGenerator.citationKey(title: "Étude", firstAuthor: "François Müller", year: 2020)
        #expect(key == "muller2020etude")
    }

    @Test("citation key: 重複時はa,b,...付与")
    func citationKeyDeduplication() {
        let existing: Set<String> = ["vaswani2017attention", "vaswani2017attentiona"]
        let key = BibtexGenerator.citationKey(
            title: "Attention Is All You Need",
            firstAuthor: "Ashish Vaswani",
            year: 2017,
            existingKeys: existing
        )
        #expect(key == "vaswani2017attentionb")
    }

    @Test("citation key: overrideが優先される")
    func citationKeyOverride() {
        let key = BibtexGenerator.citationKey(
            title: "X", firstAuthor: "Y", year: 2000, override: "mykey2000")
        #expect(key == "mykey2000")
    }

    @Test("エントリタイプ: journalあり→article")
    func entryTypeArticle() {
        var p = samplePaper(booktitle: nil)
        p.journal = "Nature"
        #expect(BibtexGenerator.entryType(for: p) == .article)
    }

    @Test("エントリタイプ: booktitleあり→inproceedings")
    func entryTypeInproceedings() {
        #expect(BibtexGenerator.entryType(for: samplePaper()) == .inproceedings)
    }

    @Test("エントリタイプ: arXivのみ→misc")
    func entryTypeMisc() {
        let p = samplePaper(doi: nil, booktitle: nil)
        #expect(BibtexGenerator.entryType(for: p) == .misc)
    }

    @Test("inproceedings出力の形式")
    func inproceedingsOutput() {
        let bibtex = BibtexGenerator().generate(
            paper: samplePaper(),
            authors: ["Ashish Vaswani", "Noam Shazeer"]
        )
        #expect(bibtex.hasPrefix("@inproceedings{vaswani2017attention,"), "プレフィックス: \(bibtex)")
        #expect(bibtex.contains("title"))
        #expect(bibtex.contains("Vaswani, Ashish and Shazeer, Noam"), "著者は姓,名+and連結: \(bibtex)")
        #expect(bibtex.contains("booktitle"))
        #expect(bibtex.contains("{2017}"))
        #expect(bibtex.hasSuffix("}"))
    }

    @Test("arXiv misc出力にeprint/archivePrefix")
    func arxivMiscOutput() {
        let bibtex = BibtexGenerator().generate(
            paper: samplePaper(doi: nil, booktitle: nil),
            authors: ["Ashish Vaswani"]
        )
        #expect(bibtex.hasPrefix("@misc{"), Comment(rawValue: bibtex))
        #expect(bibtex.contains("eprint"))
        #expect(bibtex.contains("{arXiv}"))
    }

    @Test("LaTeX特殊文字のエスケープ")
    func latexEscaping() {
        var p = samplePaper(booktitle: nil)
        p.title = "Cost & Benefit: 100% of #neural _models_"
        let bibtex = BibtexGenerator().generate(paper: p, authors: [])
        #expect(bibtex.contains(#"Cost \& Benefit"#), Comment(rawValue: bibtex))
        #expect(bibtex.contains(#"100\%"#))
        #expect(bibtex.contains("\\#neural"))
        #expect(bibtex.contains(#"\_models\_"#))
    }

    @Test("非ASCIIは既定でそのまま、asciiModeで変換")
    func asciiMode() {
        var p = samplePaper(booktitle: nil)
        p.title = "Études élégantes"
        let raw = BibtexGenerator().generate(paper: p, authors: [])
        #expect(raw.contains("Études élégantes"), Comment(rawValue: raw))
        let ascii = BibtexGenerator(options: .init(asciiMode: true)).generate(paper: p, authors: [])
        #expect(ascii.contains("Etudes elegantes"), Comment(rawValue: ascii))
    }

    @Test("preferCachedBibtexでbibtex_cachedを返す")
    func preferCachedBibtex() {
        var p = samplePaper()
        p.bibtexCached = "@article{cached, title={Cached}}"
        let result = BibtexGenerator(options: .init(preferCachedBibtex: true)).generate(paper: p, authors: [])
        #expect(result == "@article{cached, title={Cached}}")
        // 既定は動的生成
        let dynamic = BibtexGenerator().generate(paper: p, authors: [])
        #expect(dynamic.hasPrefix("@inproceedings{"), Comment(rawValue: dynamic))
    }
}
