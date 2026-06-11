import Foundation
import Testing
import PaperdCore

@Suite("PDF書き出しファイル名")
struct PaperExportTests {
    @Test("著者数による形式: 1名 / 2名 / 3名以上")
    func authorFormats() {
        let paper = samplePaper()  // year 2017
        #expect(PaperExport.filename(paper: paper, authors: ["Ashish Vaswani"])
                == "Vaswani 2017 - Attention Is All You Need.pdf")
        #expect(PaperExport.filename(paper: paper, authors: ["Ashish Vaswani", "Noam Shazeer"])
                == "Vaswani and Shazeer 2017 - Attention Is All You Need.pdf")
        #expect(PaperExport.filename(paper: paper, authors: ["Ashish Vaswani", "Noam Shazeer", "Niki Parmar"])
                == "Vaswani et al. 2017 - Attention Is All You Need.pdf")
    }

    @Test("著者・年なしのフォールバック")
    func missingFields() {
        var paper = samplePaper(title: "Some Title", year: nil)
        paper.year = nil
        #expect(PaperExport.filename(paper: paper, authors: []) == "Some Title.pdf")
        paper.year = 2020
        #expect(PaperExport.filename(paper: paper, authors: []) == "2020 - Some Title.pdf")
    }

    @Test("ファイル名に使えない文字の除去とタイトル切り詰め")
    func sanitization() {
        var paper = samplePaper(title: "BaTiO3/PbTiO3: a \"study\" <of> domain|walls?")
        let name = PaperExport.filename(paper: paper, authors: ["Hikaru Azuma"])
        #expect(name == "Azuma 2017 - BaTiO3-PbTiO3- a study of domainwalls.pdf", Comment(rawValue: name))

        paper.title = String(repeating: "Long Title ", count: 20)
        let capped = PaperExport.filename(paper: paper, authors: ["Hikaru Azuma"], maxTitleLength: 30)
        #expect(capped.count < 60)
        #expect(capped.contains("…"))
        #expect(capped.hasSuffix(".pdf"))
    }
}
