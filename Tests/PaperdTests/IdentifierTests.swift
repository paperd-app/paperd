import Foundation
import Testing
import PaperdCore

@Suite("Paper.webURL")
struct WebURLTests {
    @Test("優先順: DOI → arXiv → url")
    func priority() {
        let withDOI = samplePaper()  // doi + arxivId + url すべてあり
        #expect(withDOI.webURL?.absoluteString == "https://doi.org/10.5555/3295222.3295349")

        let arxivOnly = samplePaper(doi: nil)
        #expect(arxivOnly.webURL?.absoluteString == "https://arxiv.org/abs/1706.03762")

        var urlOnly = samplePaper(doi: nil, arxivId: nil)
        urlOnly.url = "https://example.com/paper"
        #expect(urlOnly.webURL?.absoluteString == "https://example.com/paper")

        var none = samplePaper(doi: nil, arxivId: nil)
        none.url = nil
        #expect(none.webURL == nil)
    }
}

@Suite("PaperIdentifier")
struct IdentifierTests {
    @Test("新形式arXiv IDのパースとバージョン分離")
    func newStyleArxivID() throws {
        let parsed = try #require(PaperIdentifier.parseArxivID("2403.01234v2"))
        #expect(parsed.id == "2403.01234")
        #expect(parsed.version == "v2")
    }

    @Test("バージョンなしarXiv ID")
    func arxivIDWithoutVersion() throws {
        let parsed = try #require(PaperIdentifier.parseArxivID("1706.03762"))
        #expect(parsed.id == "1706.03762")
        #expect(parsed.version == nil)
    }

    @Test("arXiv:プレフィックス")
    func arxivPrefix() throws {
        let parsed = try #require(PaperIdentifier.parseArxivID("arXiv:1706.03762v5"))
        #expect(parsed.id == "1706.03762")
        #expect(parsed.version == "v5")
    }

    @Test("旧形式arXiv ID")
    func oldStyleArxivID() throws {
        let parsed = try #require(PaperIdentifier.parseArxivID("cs.CL/0301001"))
        #expect(parsed.id == "cs.CL/0301001")
    }

    @Test("不正なarXiv IDはnil")
    func invalidArxivID() {
        #expect(PaperIdentifier.parseArxivID("12.34") == nil)
        #expect(PaperIdentifier.parseArxivID("hello") == nil)
    }

    @Test("DOIのパース")
    func doiParsing() {
        #expect(PaperIdentifier.parseDOI("10.5555/3295222.3295349") == "10.5555/3295222.3295349")
        #expect(PaperIdentifier.parseDOI("doi:10.1038/nature14539") == "10.1038/nature14539")
        #expect(PaperIdentifier.parseDOI("not-a-doi") == nil)
    }

    @Test("DOI末尾の句読点除去")
    func doiPunctuationTrim() {
        #expect(PaperIdentifier.extractDOI(from: "see 10.1038/nature14539.") == "10.1038/nature14539")
    }

    @Test("入力の自動判別: arXiv ID")
    func autoDetectArxiv() throws {
        let id = try #require(PaperIdentifier.parse("1706.03762v5"))
        #expect(id == .arxiv(id: "1706.03762", version: "v5"))
    }

    @Test("入力の自動判別: DOI")
    func autoDetectDOI() throws {
        let id = try #require(PaperIdentifier.parse("10.1038/nature14539"))
        #expect(id == .doi("10.1038/nature14539"))
    }

    @Test("URL: arxiv.org/abs")
    func urlArxivAbs() throws {
        let id = try #require(PaperIdentifier.parseURL("https://arxiv.org/abs/1706.03762v5"))
        #expect(id == .arxiv(id: "1706.03762", version: "v5"))
    }

    @Test("URL: arxiv.org/pdf（.pdf付き）")
    func urlArxivPDF() throws {
        let id = try #require(PaperIdentifier.parseURL("https://arxiv.org/pdf/1706.03762.pdf"))
        #expect(id == .arxiv(id: "1706.03762", version: nil))
    }

    @Test("URL: doi.org")
    func urlDOIOrg() throws {
        let id = try #require(PaperIdentifier.parseURL("https://doi.org/10.1038/nature14539"))
        #expect(id == .doi("10.1038/nature14539"))
    }

    @Test("URL: 中にDOIを含む出版社ページ")
    func urlWithEmbeddedDOI() throws {
        let id = try #require(PaperIdentifier.parseURL("https://dl.acm.org/doi/10.1145/3292500.3330701"))
        #expect(id == .doi("10.1145/3292500.3330701"))
    }

    @Test("URL: 直接PDF")
    func urlDirectPDF() throws {
        let id = try #require(PaperIdentifier.parseURL("https://example.com/papers/foo.pdf"))
        #expect(id == .directPDFURL("https://example.com/papers/foo.pdf"))
    }

    @Test("URL: その他のページはwebpage")
    func urlWebpage() throws {
        let id = try #require(PaperIdentifier.parseURL("https://example.com/blog/post"))
        #expect(id == .webpage("https://example.com/blog/post"))
    }
}
