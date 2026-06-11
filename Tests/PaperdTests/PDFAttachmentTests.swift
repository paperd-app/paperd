import Foundation
import Testing
import PaperdCore

/// ローカルPDF解決チェーンの改善（→ docs/04 4節）とPDF後付け（→ docs/04 6節）のテスト
@Suite("ローカルPDF解決チェーン")
struct LocalPDFResolutionChainTests {
    func makePipeline() throws -> (LibraryStore, URL, JobQueue, FakeExecutors, IngestPipeline) {
        let (store, root) = try makeTempLibrary()
        let queue = JobQueue(db: store.db)
        let executors = FakeExecutors(resolveResult: sampleResolved())
        let pipeline = IngestPipeline(store: store, queue: queue, executors: executors)
        return (store, root, queue, executors, pipeline)
    }

    func dropPDF(_ root: URL, _ queue: JobQueue, _ pipeline: IngestPipeline, content: String = "%PDF-1.4 x") async throws -> Job {
        let source = root.appendingPathComponent("drop-\(UUID().uuidString).pdf")
        try Data(content.utf8).write(to: source)
        let job = try queue.enqueue(kind: .ingest, payload: ["pdf_path": source.path], origin: .app)
        _ = try await runToCompletion(queue, pipeline, job.id)
        return try #require(try queue.job(id: job.id))
    }

    @Test("本文冒頭のDOI刷り込みからID解決される（bibliographic検索より優先）")
    func doiInTextResolution() async throws {
        let (store, root, queue, executors, pipeline) = try makePipeline()
        defer { cleanup(root) }
        executors.convertMarkdownOverride = """
        ## THEORETICAL AND MATHEMATICAL PHYSICS

        ## On Depolarization Factors of Anisotropic Ellipsoids

        DOI:

        10.5555/3295222.3295349

        ## INTRODUCTION

        Body text.
        """
        let job = try await dropPDF(root, queue, pipeline)
        let paperId = try #require(job.paperId)
        let paper = try #require(try store.paper(id: paperId))
        #expect(paper.paperStatus == .indexed)
        #expect(paper.doi == "10.5555/3295222.3295349")
        // DOI抽出 → executors.resolve(.doi) が呼ばれ、bibliographic検索は呼ばれない
        #expect(executors.resolveIdentifiers.contains(.doi("10.5555/3295222.3295349")))
        #expect(executors.bibliographicCalls.isEmpty, "タイトル検索にフォールバックしない")
    }

    @Test("本文冒頭のarXiv ID刷り込みからID解決される")
    func arxivInTextResolution() async throws {
        let (store, root, queue, executors, pipeline) = try makePipeline()
        defer { cleanup(root) }
        executors.convertMarkdownOverride = "## Some Paper\n\narXiv:1706.03762v5 [cs.CL] 12 Jun 2017\n\nBody."
        let job = try await dropPDF(root, queue, pipeline)
        let paperId = try #require(job.paperId)
        _ = try #require(try store.paper(id: paperId))
        #expect(executors.resolveIdentifiers.contains(.arxiv(id: "1706.03762", version: "v5")))
    }

    @Test("URL登録済みのmetadata_only論文へDOI一致で合流する（報告された問題の再現）")
    func mergesIntoExistingMetadataOnlyPaper() async throws {
        let (store, root, queue, executors, pipeline) = try makePipeline()
        defer { cleanup(root) }
        // URL/IDで先に書誌登録された論文（PDFなし）
        let existing = samplePaper()
        try store.savePaper(existing, authors: sampleAuthors)
        #expect(existing.paperStatus == .metadataOnly)

        // PDFをドロップ → 本文のDOIが既存行と一致 → 合流
        executors.convertMarkdownOverride = "## Title\n\nDOI: 10.5555/3295222.3295349\n\nBody text here."
        let job = try await dropPDF(root, queue, pipeline)

        #expect(job.paperId == existing.id, "既存行のIDが正")
        let papers = try store.allPapers()
        #expect(papers.count == 1, "別エントリは作られない")
        let merged = try #require(try store.paper(id: existing.id))
        #expect(merged.paperStatus == .indexed)
        #expect(merged.pdfHash?.hasPrefix("sha256:") == true)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: store.layout.pdfPath(existing.id).path), "PDFが既存行のディレクトリへ")
        #expect(fm.fileExists(atPath: store.layout.markdownPath(existing.id).path))
    }

    @Test("ID抽出も書誌解決も失敗 → タイトル一致でmetadata_only行へ合流（ネットワーク不要）")
    func fallbackTitleMatchMerge() async throws {
        let (store, root, queue, executors, pipeline) = try makePipeline()
        defer { cleanup(root) }
        let existing = samplePaper(title: "On Depolarization Factors of Anisotropic Ellipsoids in an Anisotropic Medium",
                                   doi: "10.1134/s1063784214120020", arxivId: nil)
        try store.savePaper(existing, authors: [])

        executors.bibliographicResult = nil  // 書誌解決失敗
        executors.convertMarkdownOverride = """
        ## THEORETICAL AND MATHEMATICAL PHYSICS

        ## On Depolarization Factors of Anisotropic Ellipsoids in an Anisotropic Medium

        Body text without printed identifiers.
        """
        executors.convertDoclingOverride = #"{"texts": [], "tables": []}"#
        let job = try await dropPDF(root, queue, pipeline)

        #expect(job.paperId == existing.id)
        #expect(try store.allPapers().count == 1)
        let merged = try #require(try store.paper(id: existing.id))
        #expect(merged.paperStatus == .indexed)
        #expect(merged.title == existing.title, "既存メタデータは保持")
        #expect(merged.doi == existing.doi)
    }

    @Test("書誌解決結果のタイトル検証: 本文と無関係な解決結果は不採用でpdf_only")
    func rejectsMismatchedBibliographicResult() async throws {
        let (store, root, queue, executors, pipeline) = try makePipeline()
        defer { cleanup(root) }
        // 誤った候補（誌名）で検索された結果、無関係な論文が返るケース
        var wrong = sampleResolved()
        wrong.title = "A Completely Different Study About Feline Behavior Patterns"
        executors.bibliographicResult = wrong
        executors.convertMarkdownOverride = "## SOME JOURNAL HEADER NAME HERE\n\nBody text without identifiers."
        executors.convertDoclingOverride = """
        {"texts": [{"label": "section_header", "text": "SOME JOURNAL HEADER NAME HERE", "level": 1, "prov": [{"page_no": 1, "bbox": {"t": 700}}]}]}
        """
        let job = try await dropPDF(root, queue, pipeline)
        let paperId = try #require(job.paperId)
        let paper = try #require(try store.paper(id: paperId))
        #expect(paper.paperStatus == .pdfOnly, "不確かな一致は採用しない")
        #expect(paper.doi == nil)
    }

    @Test("タイトル候補: 全大文字のランニングヘッダより通常表記の見出しを優先")
    func titleCandidatePrefersNonAllCaps() {
        let items = [
            DoclingItem(kind: .sectionHeader(level: 1), text: "THEORETICAL AND MATHEMATICAL PHYSICS", page: 1),
            DoclingItem(kind: .sectionHeader(level: 1), text: "On Depolarization Factors of Anisotropic Ellipsoids", page: 1),
        ]
        #expect(DoclingParser.titleCandidate(items: items)?.hasPrefix("On Depolarization") == true)
        // 全大文字しかなければそれを使う
        let capsOnly = [DoclingItem(kind: .sectionHeader(level: 1), text: "ALL CAPS TITLE OF THIS PAPER", page: 1)]
        #expect(DoclingParser.titleCandidate(items: capsOnly) == "ALL CAPS TITLE OF THIS PAPER")
    }

    @Test("本文からのID抽出ヘルパー")
    func identifierExtraction() {
        #expect(PaperIdentifier.extractDOI(from: "DOI:\n\n10.1134/S1063784214120020\n") == "10.1134/S1063784214120020")
        let arxiv = PaperIdentifier.extractArxivID(from: "arXiv:2403.01234v2 [cs.CL]")
        #expect(arxiv?.id == "2403.01234" && arxiv?.version == "v2")
        #expect(PaperIdentifier.extractArxivID(from: "no id here") == nil)
    }

    @Test("TextMatch: 正規化包含とトークン重なり")
    func textMatching() {
        #expect(TextMatch.containsNormalized(
            "## On Depolarization Factors of Anisotropic Ellipsoids in an Anisotropic Medium\n\nbody",
            "On depolarization factors of anisotropic ellipsoids in an anisotropic medium"))
        #expect(!TextMatch.containsNormalized("unrelated text", "On depolarization factors"))
        #expect(TextMatch.tokenOverlap("Attention Is All You Need", "attention is all you need") == 1.0)
        #expect(TextMatch.tokenOverlap("Attention Is All You Need", "Feline Behavior Patterns") < 0.1)
    }
}

@Suite("PDF後付け（attachPDF）")
struct PDFAttachTests {
    @Test("metadata_only論文へ添付 → convert以降が再開されindexed")
    func attachAndResume() async throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        let executors = FakeExecutors(resolveResult: sampleResolved())
        let pipeline = IngestPipeline(store: store, queue: queue, executors: executors)

        let paper = samplePaper()
        try store.savePaper(paper, authors: sampleAuthors)

        let source = root.appendingPathComponent("manual.pdf")
        try Data("%PDF-1.4 manual".utf8).write(to: source)
        try store.attachPDF(paperId: paper.id, from: source)

        let updated = try #require(try store.paper(id: paper.id))
        #expect(updated.pdfHash?.hasPrefix("sha256:") == true)
        #expect(FileManager.default.fileExists(atPath: store.layout.pdfPath(paper.id).path))

        // convert以降の再開（completedStage: .fetch → resolveは走らない）
        let job = try queue.enqueue(kind: .ingest, paperId: paper.id, payload: [:], origin: .app, completedStage: .fetch)
        _ = try queue.claim(job.id)
        let status = try await pipeline.run(job: try #require(try queue.job(id: job.id)))
        #expect(status == .indexed)
        #expect(executors.resolveCalls == 0, "resolveは再実行されない")
        #expect(executors.convertCalls == 1)
        #expect(try store.paper(id: paper.id)?.paperStatus == .indexed)
    }

    @Test("既にPDFがある論文への添付はエラー")
    func attachToExistingPDFFails() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let paper = samplePaper()
        try store.savePaper(paper, authors: [])
        try FileManager.default.createDirectory(at: store.layout.paperDir(paper.id), withIntermediateDirectories: true)
        try Data("%PDF-1.4 a".utf8).write(to: store.layout.pdfPath(paper.id))
        let source = root.appendingPathComponent("b.pdf")
        try Data("%PDF-1.4 b".utf8).write(to: source)
        #expect(throws: (any Error).self) {
            try store.attachPDF(paperId: paper.id, from: source)
        }
    }

    @Test("別論文として登録済みのPDF（hash一致）の添付はduplicateエラー")
    func attachDuplicateHashFails() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        var other = samplePaper(title: "Other", doi: "10.1/other", arxivId: nil)
        other.pdfHash = "sha256:" + (try IngestPipeline.sha256(of: {
            let url = root.appendingPathComponent("same.pdf")
            try! Data("%PDF-1.4 same".utf8).write(to: url)
            return url
        }()))
        try store.savePaper(other, authors: [])
        let target = samplePaper()
        try store.savePaper(target, authors: [])

        #expect(throws: IngestError.duplicate(existingPaperId: other.id)) {
            try store.attachPDF(paperId: target.id, from: root.appendingPathComponent("same.pdf"))
        }
    }
}
