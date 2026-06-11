import Foundation
import Testing
import PaperdCore

/// citation_*メタタグからのWebページ解決（→ docs/04 2節。NeurIPS URL失敗の回帰テスト）
@Suite("Webページ解決")
struct WebpageResolutionTests {
    let neuripsHTML = """
    <html><head>
    <meta name="citation_title" content="Attention is All you Need">
    <meta name="citation_author" content="Vaswani, Ashish">
    <meta name="citation_author" content="Shazeer, Noam">
    <meta name="citation_journal_title" content="Advances in Neural Information Processing Systems">
    <meta name="citation_volume" content="30">
    <meta name="citation_publication_date" content="2017">
    <meta name="citation_pdf_url" content="https://proceedings.neurips.cc/paper_files/paper/2017/file/x-Paper.pdf">
    </head><body></body></html>
    """

    @Test("メタタグ解析: タイトル・著者・年・誌名・PDF URL")
    func parseTags() {
        let meta = WebpageMetadata.parse(html: neuripsHTML)
        #expect(meta.title == "Attention is All you Need")
        #expect(meta.authors == ["Ashish Vaswani", "Noam Shazeer"], "姓,名 → 名 姓 に正規化")
        #expect(meta.year == 2017)
        #expect(meta.journal == "Advances in Neural Information Processing Systems")
        #expect(meta.volume == "30")
        #expect(meta.pdfURL?.hasSuffix("-Paper.pdf") == true)
    }

    @Test("メタタグ解析: 属性順の入れ替え・エンティティ・content先行")
    func parseVariants() {
        let html = #"<meta content="Deep &amp; Wide" name="CITATION_TITLE"><meta content="10.1234/x.5" name="citation_doi">"#
        let meta = WebpageMetadata.parse(html: html)
        #expect(meta.title == "Deep & Wide")
        #expect(meta.doi == "10.1234/x.5")
    }

    @Test("citation_doiがあればID解決に帰着しpdf_urlを保持")
    func doiTagDelegates() async throws {
        let http = StubHTTPClient()
        http.add("example.org/abstract", body: #"<meta name="citation_doi" content="10.5555/3295222.3295349"><meta name="citation_pdf_url" content="https://example.org/x.pdf">"#)
        http.add("api.crossref.org/works/10.5555", body: """
            {"status":"ok","message":{"DOI":"10.5555/3295222.3295349","title":["Attention Is All You Need"],
             "author":[{"given":"Ashish","family":"Vaswani"}],"issued":{"date-parts":[[2017]]},
             "container-title":["NeurIPS"],"type":"proceedings-article"}}
            """)
        let resolver = MetadataResolver.live(http: http)
        let meta = try await resolver.resolve(.webpage("https://example.org/abstract.html"))
        #expect(meta.doi == "10.5555/3295222.3295349")
        #expect(meta.title == "Attention Is All You Need")
        #expect(meta.pdfURL == "https://example.org/x.pdf", "ページのcitation_pdf_urlを保持")
    }

    @Test("DOIなしページ: タグの書誌を採用（NeurIPSケース）")
    func tagOnlyResolution() async throws {
        let http = StubHTTPClient()
        http.add("proceedings.neurips.cc", body: neuripsHTML)
        // Crossref bibliographic検索はヒットなし
        http.add("api.crossref.org/works?", body: #"{"status":"ok","message":{"items":[]}}"#)
        let resolver = MetadataResolver.live(http: http)
        let meta = try await resolver.resolve(.webpage("https://proceedings.neurips.cc/paper/2017/hash/3f5ee243-Abstract.html"))
        #expect(meta.title == "Attention is All you Need")
        #expect(meta.authors.map(\.displayName) == ["Ashish Vaswani", "Noam Shazeer"])
        #expect(meta.year == 2017)
        #expect(meta.journal == "Advances in Neural Information Processing Systems")
        #expect(meta.pdfURL?.contains("Paper.pdf") == true)
        #expect(meta.url?.contains("Abstract.html") == true)
    }

    @Test("メタタグの無いページは恒久的エラー（parse）")
    func tagLessPageIsPermanent() async throws {
        let http = StubHTTPClient()
        http.add("example.org", body: "<html><body>blog post</body></html>")
        let resolver = MetadataResolver.live(http: http)
        do {
            _ = try await resolver.resolve(.webpage("https://example.org/post"))
            Issue.record("parseエラーになるはず")
        } catch let error as MetadataError {
            guard case .parse = error else { Issue.record("parse以外: \(error)"); return }
        }
    }
}

/// パイプライン側のURL取り込み挙動（→ docs/04 2節）
@Suite("URL取り込みのパイプライン挙動")
struct URLIngestPipelineTests {
    @Test("解決不能（notFound/parse）はリトライせず即failed")
    func unresolvableFailsPermanently() async throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        let executors = FakeExecutors(resolveResult: sampleResolved())
        executors.resolveError = MetadataError.parse(source: "webpage", message: "citationメタタグが見つかりません")
        let pipeline = IngestPipeline(store: store, queue: queue, executors: executors)

        let job = try queue.enqueue(kind: .ingest, payload: ["input": "https://example.org/post"], origin: .app)
        await #expect(throws: (any Error).self) {
            _ = try await runToCompletion(queue, pipeline, job.id)
        }
        let failed = try #require(try queue.job(id: job.id))
        #expect(failed.jobStatus == .failed)
        #expect(failed.retryCount == 0, "無駄な3リトライをしない")
        #expect(executors.resolveCalls == 1)
    }

    @Test("直接PDF URL: ダウンロード → ローカルPDF解決チェーンへ")
    func directPDFDownloads() async throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        let executors = FakeExecutors(resolveResult: sampleResolved())
        executors.bibliographicResult = sampleResolved()
        let pipeline = IngestPipeline(store: store, queue: queue, executors: executors)

        let job = try queue.enqueue(kind: .ingest, payload: ["input": "https://example.org/papers/attention.pdf"], origin: .app)
        let status = try await runToCompletion(queue, pipeline, job.id)
        #expect(status == .indexed)
        #expect(executors.downloadedURLs.map(\.absoluteString) == ["https://example.org/papers/attention.pdf"])
        let paperId = try #require(try queue.job(id: job.id)?.paperId)
        #expect(FileManager.default.fileExists(atPath: store.layout.pdfPath(paperId).path), "PDFがライブラリへ取り込まれる")
    }
}

/// resolve中に確定したpdf_urlが同一run内のfetchへ届く（NeurIPS metadata_only止まりの回帰テスト）
@Suite("pdf_urlのステージ間伝搬")
struct PDFURLPropagationTests {
    @Test("resolveのpdfURLがfetchPDFに渡る")
    func pdfURLReachesFetch() async throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        var resolved = sampleResolved()
        resolved.pdfURL = "https://proceedings.neurips.cc/file/x-Paper.pdf"
        let executors = FakeExecutors(resolveResult: resolved)
        let pipeline = IngestPipeline(store: store, queue: queue, executors: executors)

        let job = try queue.enqueue(kind: .ingest, payload: ["input": "https://proceedings.neurips.cc/hash/x-Abstract.html"], origin: .app)
        let status = try await runToCompletion(queue, pipeline, job.id)
        #expect(status == .indexed)
        #expect(executors.fetchedPDFURLs == ["https://proceedings.neurips.cc/file/x-Paper.pdf"],
                "resolve中に保存したpdf_urlが同一runのfetchで使われる")
    }
}

/// クリップボードプリフィルの判定（→ docs/09 7節）
@Suite("取り込みプリフィル判定")
struct ImportPrefillTests {
    @Test("URL / DOI / arXiv IDは対象、ローカルパス・自由文は対象外")
    func eligibility() {
        #expect(PaperIdentifier.isImportable("https://proceedings.neurips.cc/paper/2017/hash/x-Abstract.html"))
        #expect(PaperIdentifier.isImportable("10.1063/5.0138489"))
        #expect(PaperIdentifier.isImportable("1706.03762"))
        #expect(PaperIdentifier.isImportable("  https://arxiv.org/abs/1706.03762  "), "前後空白は許容")
        #expect(!PaperIdentifier.isImportable("/Users/me/paper.pdf"), "ローカルパスは充填しない")
        #expect(!PaperIdentifier.isImportable("会議のメモ書き"), "自由文は充填しない")
        #expect(!PaperIdentifier.isImportable("line1\nline2"), "複数行は充填しない")
        #expect(!PaperIdentifier.isImportable(""))
    }
}

/// paywall時の代替PDF探索（→ docs/04 3節・6節）
@Suite("代替PDFの補完")
struct AlternativePDFTests {
    @Test("S2補完で出版版DOIにarXiv IDが付く + OpenAlexのOAリンクがpdfURLに入る")
    func complementBridgesPreprint() async throws {
        let http = StubHTTPClient()
        // Crossref: 出版版（PRL。arXiv情報なし）
        http.add("api.crossref.org/works/10.1103", body: """
            {"status":"ok","message":{"DOI":"10.1103/PhysRevLett.115.036402",
             "title":["Strongly Constrained and Appropriately Normed Semilocal Density Functional"],
             "author":[{"given":"Jianwei","family":"Sun"}],"issued":{"date-parts":[[2015]]},
             "container-title":["Physical Review Letters"],"type":"journal-article"}}
            """)
        // S2: externalIdsにArXiv
        http.add("api.semanticscholar.org", body: """
            {"paperId": "s2-scan", "title": "SCAN", "year": 2015,
             "externalIds": {"ArXiv": "1504.03028", "DOI": "10.1103/PhysRevLett.115.036402"}, "authors": []}
            """)
        // OpenAlex: best_oa_locationにOA PDF
        http.add("api.openalex.org", body: """
            {"id": "https://openalex.org/W1", "display_name": "SCAN", "publication_year": 2015,
             "best_oa_location": {"pdf_url": "https://arxiv.org/pdf/1504.03028"}}
            """)
        let resolver = MetadataResolver.live(http: http)
        let meta = try await resolver.resolve(.doi("10.1103/PhysRevLett.115.036402"))

        #expect(meta.arxivId == "1504.03028", "S2のexternalIdsからarXiv IDが補完される")
        #expect(meta.pdfURL == "https://arxiv.org/pdf/1504.03028", "OpenAlexのOAリンクがPDF候補に")
        #expect(meta.journal == "Physical Review Letters")
    }
}
