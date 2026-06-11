import Foundation
import Testing
import PaperdCore

let arxivAtomFixture = """
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <id>http://arxiv.org/abs/1706.03762v5</id>
    <published>2017-06-12T17:57:34Z</published>
    <title>Attention Is All You Need</title>
    <summary>The dominant sequence transduction models are based on complex
  recurrent or convolutional neural networks.</summary>
    <author><name>Ashish Vaswani</name></author>
    <author><name>Noam Shazeer</name></author>
    <arxiv:doi xmlns:arxiv="http://arxiv.org/schemas/atom">10.5555/3295222.3295349</arxiv:doi>
  </entry>
</feed>
"""

let crossrefFixture = """
{
  "status": "ok",
  "message": {
    "DOI": "10.5555/3295222.3295349",
    "type": "proceedings-article",
    "title": ["Attention Is All You Need"],
    "container-title": ["Advances in Neural Information Processing Systems"],
    "author": [
      {"given": "Ashish", "family": "Vaswani"},
      {"given": "Noam", "family": "Shazeer", "ORCID": "http://orcid.org/0000-0000-0000-0001"}
    ],
    "published-print": {"date-parts": [[2017, 12]]},
    "publisher": "Curran Associates",
    "page": "5998-6008",
    "URL": "http://dx.doi.org/10.5555/3295222.3295349"
  }
}
"""

let s2Fixture = """
{
  "paperId": "204e3073870fae3d05bcbc2f6a8e263d9b72e776",
  "title": "Attention is All you Need",
  "abstract": "S2 abstract text.",
  "year": 2017,
  "venue": "Neural Information Processing Systems",
  "citationCount": 100000,
  "externalIds": {"DOI": "10.5555/3295222.3295349", "ArXiv": "1706.03762"},
  "authors": [{"authorId": "1738948", "name": "Ashish Vaswani"}]
}
"""

let openAlexFixture = """
{
  "id": "https://openalex.org/W2741809807",
  "display_name": "Attention Is All You Need",
  "publication_year": 2017,
  "doi": "https://doi.org/10.5555/3295222.3295349",
  "abstract_inverted_index": {"The": [0], "dominant": [1], "models": [2]}
}
"""

@Suite("MetadataClients")
struct MetadataClientTests {
    @Test("ArxivClient: AtomフィードからResolvedMetadata")
    func arxivAtomParsing() async throws {
        let http = StubHTTPClient()
        http.add("export.arxiv.org", body: arxivAtomFixture)
        let client = ArxivClient(http: http)
        let meta = try await client.resolve(arxivId: "1706.03762")
        #expect(meta.title == "Attention Is All You Need")
        #expect(meta.year == 2017)
        #expect(meta.arxivId == "1706.03762")
        #expect(meta.arxivVersion == "v5")
        #expect(meta.doi == "10.5555/3295222.3295349")
        #expect(meta.authors.map(\.displayName) == ["Ashish Vaswani", "Noam Shazeer"])
        #expect(meta.pdfURL == "https://arxiv.org/pdf/1706.03762")
        let abstract = try #require(meta.abstract)
        #expect(abstract.contains("sequence transduction"), "summary連結: \(abstract)")
    }

    @Test("CrossrefClient: works JSONの解析")
    func crossrefParsing() async throws {
        let http = StubHTTPClient()
        http.add("api.crossref.org/works/", body: crossrefFixture)
        let client = CrossrefClient(http: http, mailto: "user@example.com")
        let meta = try await client.resolve(doi: "10.5555/3295222.3295349")
        #expect(meta.title == "Attention Is All You Need")
        #expect(meta.bibtexType == "inproceedings")
        #expect(meta.booktitle == "Advances in Neural Information Processing Systems")
        #expect(meta.year == 2017)
        #expect(meta.pages == "5998-6008")
        #expect(meta.publisher == "Curran Associates")
        #expect(meta.authors.count == 2)
        // mailtoパラメータが付与される（politeプール → docs/04 9節）
        #expect(http.requests[0].url.absoluteString.contains("mailto=user@example.com"))
    }

    @Test("Crossref 404はnotFound")
    func crossrefNotFound() async throws {
        let http = StubHTTPClient()
        http.add("api.crossref.org", status: 404, body: "{}")
        let client = CrossrefClient(http: http)
        await #expect(throws: MetadataError.notFound(source: "Crossref", identifier: "10.9999/nope")) {
            _ = try await client.resolve(doi: "10.9999/nope")
        }
    }

    @Test("SemanticScholarClient: paper取得")
    func s2Paper() async throws {
        let http = StubHTTPClient()
        http.add("api.semanticscholar.org", body: s2Fixture)
        let client = SemanticScholarClient(http: http, apiKey: "test-key")
        let info = try await client.paper(identifier: "ARXIV:1706.03762")
        #expect(info.paperId == "204e3073870fae3d05bcbc2f6a8e263d9b72e776")
        #expect(info.abstract == "S2 abstract text.")
        #expect(info.citationCount == 100000)
        #expect(info.authors.first?.s2AuthorId == "1738948")
        // APIキーはx-api-keyヘッダで送る（→ docs/08 1節）
        #expect(http.requests[0].headers["x-api-key"] == "test-key")
    }

    @Test("OpenAlexClient: inverted indexからabstract復元")
    func openAlexAbstract() async throws {
        let http = StubHTTPClient()
        http.add("api.openalex.org", body: openAlexFixture)
        let client = OpenAlexClient(http: http)
        let work = try await client.work(doi: "10.5555/3295222.3295349")
        #expect(work.openalexId == "W2741809807")
        #expect(work.abstract == "The dominant models")
        #expect(work.doi == "10.5555/3295222.3295349")
    }
}

@Suite("MetadataResolver")
struct MetadataResolverTests {
    @Test("arXiv ID解決: arXiv→Crossref→S2/OpenAlex補完の統合")
    func arxivResolution() async throws {
        let http = StubHTTPClient()
        http.add("export.arxiv.org", body: arxivAtomFixture)
        http.add("api.crossref.org", body: crossrefFixture)
        http.add("api.semanticscholar.org", body: s2Fixture)
        http.add("api.openalex.org", body: openAlexFixture)
        let resolver = MetadataResolver.live(http: http)

        let meta = try await resolver.resolve(.arxiv(id: "1706.03762", version: nil))
        // 出版情報を優先（Crossref）
        #expect(meta.bibtexType == "inproceedings")
        #expect(meta.booktitle == "Advances in Neural Information Processing Systems")
        // arXiv情報の保持
        #expect(meta.arxivId == "1706.03762")
        #expect(meta.arxivVersion == "v5")
        // S2 / OpenAlex補完
        #expect(meta.s2PaperId == "204e3073870fae3d05bcbc2f6a8e263d9b72e776")
        #expect(meta.openalexId == "W2741809807")
    }

    @Test("補完失敗は致命的でない")
    func complementFailureTolerated() async throws {
        let http = StubHTTPClient()
        http.add("export.arxiv.org", body: arxivAtomFixture)
        http.add("api.crossref.org", status: 500, body: "")
        // S2 / OpenAlexは404のまま
        let resolver = MetadataResolver.live(http: http)
        let meta = try await resolver.resolve(.arxiv(id: "1706.03762", version: nil))
        #expect(meta.title == "Attention Is All You Need")
        #expect(meta.s2PaperId == nil)
    }

    @Test("DOI解決")
    func doiResolution() async throws {
        let http = StubHTTPClient()
        http.add("api.crossref.org", body: crossrefFixture)
        http.add("api.semanticscholar.org", body: s2Fixture)
        http.add("api.openalex.org", body: openAlexFixture)
        let resolver = MetadataResolver.live(http: http)
        let meta = try await resolver.resolve(.doi("10.5555/3295222.3295349"))
        #expect(meta.title == "Attention Is All You Need")
        #expect(meta.abstract == "S2 abstract text.", "Crossref欠落をS2で補完")
    }
}
