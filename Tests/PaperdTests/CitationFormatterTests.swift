import Foundation
import Testing
import PaperdCore

/// 整形済み引用文の生成（→ docs/02 2.4節）
@Suite("CitationFormatter")
struct CitationFormatterTests {
    func journalPaper() -> (Paper, [Author]) {
        var paper = samplePaper(title: "Attention is all you need", booktitle: nil)
        paper.journal = "Advances in Neural Information Processing Systems"
        paper.volume = "30"
        paper.pages = "5998-6008"
        let authors = [Author(displayName: "Ashish Vaswani"), Author(displayName: "Noam Shazeer"), Author(displayName: "Niki Parmar")]
        return (paper, authors)
    }

    @Test("APA 7: 著者(年). タイトル. 誌名, 巻, ページ. DOI")
    func apaStyle() {
        let (paper, authors) = journalPaper()
        let citation = CitationFormatter.format(paper: paper, authors: authors, style: .apa)
        #expect(citation == "Vaswani, A., Shazeer, N., & Parmar, N. (2017). Attention is all you need. Advances in Neural Information Processing Systems, 30, 5998-6008. https://doi.org/10.5555/3295222.3295349",
                Comment(rawValue: citation))
    }

    @Test("MLA 9: 3名以上はet al")
    func mlaStyle() {
        let (paper, authors) = journalPaper()
        let citation = CitationFormatter.format(paper: paper, authors: authors, style: .mla)
        #expect(citation == #"Vaswani, Ashish, et al. "Attention is all you need." Advances in Neural Information Processing Systems, vol. 30, 2017, pp. 5998-6008."#,
                Comment(rawValue: citation))
    }

    @Test("Chicago: 著者. 年. \"タイトル.\" 誌名 巻: ページ")
    func chicagoStyle() {
        let (paper, authors) = journalPaper()
        let citation = CitationFormatter.format(paper: paper, authors: authors, style: .chicago)
        #expect(citation.hasPrefix("Vaswani, Ashish, Noam Shazeer, and Niki Parmar. 2017."), Comment(rawValue: citation))
        #expect(citation.contains("Advances in Neural Information Processing Systems 30: 5998-6008."))
    }

    @Test("IEEE: イニシャル先行・カンマ区切り")
    func ieeeStyle() {
        let (paper, authors) = journalPaper()
        let citation = CitationFormatter.format(paper: paper, authors: authors, style: .ieee)
        #expect(citation == #"A. Vaswani, N. Shazeer, and N. Parmar, "Attention is all you need," Advances in Neural Information Processing Systems, vol. 30, pp. 5998-6008, 2017."#,
                Comment(rawValue: citation))
    }

    @Test("Vancouver: 姓+イニシャル連結・年;巻:ページ")
    func vancouverStyle() {
        let (paper, authors) = journalPaper()
        let citation = CitationFormatter.format(paper: paper, authors: authors, style: .vancouver)
        #expect(citation == "Vaswani A, Shazeer N, Parmar N. Attention is all you need. Advances in Neural Information Processing Systems. 2017;30:5998-6008.",
                Comment(rawValue: citation))
    }

    @Test("arXivのみ（出版情報なし）の論文")
    func arxivOnly() {
        var paper = samplePaper(title: "Some Preprint", doi: nil, booktitle: nil)
        paper.venue = nil
        let citation = CitationFormatter.format(paper: paper, authors: [Author(displayName: "Jane Doe")], style: .apa)
        #expect(citation == "Doe, J. (2017). Some Preprint. arXiv. https://arxiv.org/abs/1706.03762", Comment(rawValue: citation))
    }

    @Test("著者なし・年なしでも壊れない")
    func missingFields() {
        var paper = Paper(title: "Untitled Work")
        paper.year = nil
        let citation = CitationFormatter.format(paper: paper, authors: [], style: .apa)
        #expect(citation.contains("(n.d.)"))
        #expect(citation.contains("Untitled Work"))
    }

    @Test("「姓, 名」形式の著者名も分解できる")
    func commaNameFormat() {
        let (paper, _) = journalPaper()
        let citation = CitationFormatter.format(
            paper: paper, authors: [Author(displayName: "Vaswani, Ashish")], style: .apa)
        #expect(citation.hasPrefix("Vaswani, A. (2017)."), Comment(rawValue: citation))
    }
}
