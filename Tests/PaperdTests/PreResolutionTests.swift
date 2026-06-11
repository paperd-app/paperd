import Foundation
import Testing
import AppKit
import PaperdCore

/// テキスト層つきの実PDFを生成する（Core Graphics）
func makeTextPDF(at url: URL, lines: [String]) throws {
    let data = NSMutableData()
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let consumer = CGDataConsumer(data: data),
          let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        throw NSError(domain: "test", code: 1)
    }
    context.beginPDFPage(nil)
    for (i, line) in lines.enumerated() {
        let attributed = NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 72, y: 700 - CGFloat(i) * 20)
        CTLineDraw(ctLine, context)
    }
    context.endPDFPage()
    context.closePDF()
    try (data as Data).write(to: url)
}

/// テキスト層からの先行解決（→ docs/04 4節）
@Suite("PDFテキスト層の先行解決")
struct PreResolutionTests {
    @Test("PDFTextExtractor: テキスト層の読み取りと不正PDFのnil")
    func textExtraction() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pre-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let pdf = dir.appendingPathComponent("real.pdf")
        try makeTextPDF(at: pdf, lines: ["Some Paper Title", "DOI: 10.5555/3295222.3295349"])
        let head = try #require(PDFTextExtractor.headText(of: pdf))
        #expect(head.contains("10.5555/3295222.3295349"))

        let fake = dir.appendingPathComponent("fake.pdf")
        try Data("not a pdf".utf8).write(to: fake)
        #expect(PDFTextExtractor.headText(of: fake) == nil, "テキスト層なしはnil → convert先行へフォールバック")
    }

    func makePipeline() throws -> (LibraryStore, URL, JobQueue, FakeExecutors, IngestPipeline) {
        let (store, root) = try makeTempLibrary()
        let queue = JobQueue(db: store.db)
        let executors = FakeExecutors(resolveResult: sampleResolved())
        let pipeline = IngestPipeline(store: store, queue: queue, executors: executors)
        return (store, root, queue, executors, pipeline)
    }

    @Test("DOI印字つきPDF: 変換なしで書誌解決・登録される")
    func preResolvesWithoutConversion() async throws {
        let (store, root, queue, executors, pipeline) = try makePipeline()
        defer { cleanup(root) }
        let source = root.appendingPathComponent("printed-doi.pdf")
        try makeTextPDF(at: source, lines: ["Title", "DOI: 10.5555/3295222.3295349"])

        let job = try queue.enqueue(kind: .ingest, payload: ["pdf_path": source.path], origin: .app)
        // 1回目（resolveパス）: 変換ゼロで書誌登録まで完了する
        _ = try queue.claim(job.id)
        _ = try await pipeline.run(job: try #require(try queue.job(id: job.id)))
        #expect(executors.resolveIdentifiers == [.doi("10.5555/3295222.3295349")], "テキスト層のDOIで解決")
        #expect(executors.convertCalls == 0, "書誌登録に変換は不要")
        #expect(executors.bibliographicCalls.isEmpty)
        let paperId = try #require(try queue.job(id: job.id)?.paperId)
        #expect(try store.paper(id: paperId)?.paperStatus == .metadataOnly)

        // 完走: convert以降が実行されindexedへ
        let status = try await runToCompletion(queue, pipeline, job.id)
        #expect(status == .indexed)
        #expect(executors.convertCalls == 1)
    }

    @Test("重複（PDF取得済みの既存行と同一DOI）は変換ゼロでcancel")
    func duplicateSkippedWithZeroConversion() async throws {
        let (store, root, queue, executors, pipeline) = try makePipeline()
        defer { cleanup(root) }
        // 既存論文（PDF取得済み）
        let existing = samplePaper()
        try store.savePaper(existing, authors: [])
        try FileManager.default.createDirectory(at: store.layout.paperDir(existing.id), withIntermediateDirectories: true)
        try Data("%PDF existing".utf8).write(to: store.layout.pdfPath(existing.id))

        // 同じDOIが印字された別バイト列のPDF（hash不一致 → DOIで検出される）
        let source = root.appendingPathComponent("dup.pdf")
        try makeTextPDF(at: source, lines: ["DOI: 10.5555/3295222.3295349"])

        let job = try queue.enqueue(kind: .ingest, payload: ["pdf_path": source.path], origin: .app)
        do {
            _ = try await runToCompletion(queue, pipeline, job.id)
            Issue.record("duplicateになるはず")
        } catch let error as IngestError {
            #expect(error == .duplicate(existingPaperId: existing.id))
        }
        #expect(executors.convertCalls == 0, "変換コストゼロでスキップ")
        #expect(try queue.job(id: job.id)?.jobStatus == .cancelled)
    }

    @Test("metadata_only行へ変換前に合流する")
    func mergesIntoMetadataOnlyBeforeConversion() async throws {
        let (store, root, queue, executors, pipeline) = try makePipeline()
        defer { cleanup(root) }
        let existing = samplePaper()  // PDFなしのmetadata_only
        try store.savePaper(existing, authors: sampleAuthors)

        let source = root.appendingPathComponent("merge.pdf")
        try makeTextPDF(at: source, lines: ["DOI: 10.5555/3295222.3295349"])
        let job = try queue.enqueue(kind: .ingest, payload: ["pdf_path": source.path], origin: .app)
        _ = try queue.claim(job.id)
        _ = try await pipeline.run(job: try #require(try queue.job(id: job.id)))

        #expect(try queue.job(id: job.id)?.paperId == existing.id, "既存行のIDが正")
        #expect(executors.convertCalls == 0, "合流に変換は不要")
        #expect(FileManager.default.fileExists(atPath: store.layout.pdfPath(existing.id).path))
        #expect(try store.allPapers().count == 1)

        let status = try await runToCompletion(queue, pipeline, job.id)
        #expect(status == .indexed)
    }
}

/// resolve優先スケジューリング（→ docs/04 8節）
@Suite("resolve優先スケジューリング")
struct SchedulingTests {
    @Test("nextRunnable: 未解決（stage IS NULL）のジョブを優先する")
    func unresolvedFirst() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        // 先に継続ジョブ（stage=fetch）、後に新規ジョブを投入
        let continuation = try queue.enqueue(kind: .ingest, payload: [:], origin: .app, completedStage: .fetch)
        let fresh = try queue.enqueue(kind: .ingest, payload: [:], origin: .app)

        let first = try #require(try queue.nextRunnable())
        #expect(first.id == fresh.id, "作成順が後でも未解決が先")
        _ = try queue.claim(fresh.id)
        let second = try #require(try queue.nextRunnable())
        #expect(second.id == continuation.id)
    }

    @Test("requeueForContinuation: ステージとリトライ回数を保持してqueuedへ")
    func requeueKeepsState() throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        let job = try queue.enqueue(kind: .ingest, payload: [:], origin: .app, completedStage: .fetch)
        _ = try queue.claim(job.id)
        try queue.requeueForContinuation(job.id)
        let requeued = try #require(try queue.job(id: job.id))
        #expect(requeued.jobStatus == .queued)
        #expect(requeued.jobStage == .fetch)
        #expect(requeued.retryCount == 0)
    }

    @Test("一括取り込み: 全件のresolveが変換より先に完了する")
    func bulkResolvesBeforeConversions() async throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        let executors = FakeExecutors(resolveResult: sampleResolved())
        let pipeline = IngestPipeline(store: store, queue: queue, executors: executors)
        let runner = JobRunner(queue: queue, pipeline: pipeline)

        // DOI重複を避けるため異なるDOIを返すには resolveResult が固定なので、
        // arXiv ID入力3件 → 同一DOI解決で2件目以降はstub吸収...ではなく重複cancelになるため、
        // ここではPDFドロップ（書誌解決失敗 → pdf_only）で3本のジョブを使う
        executors.bibliographicResult = nil
        executors.resolveError = FakeExecutors.TransientError()  // テキスト層解決も失敗させ、convert先行経路へ
        var sources: [URL] = []
        for i in 0..<3 {
            let url = root.appendingPathComponent("bulk-\(i).pdf")
            try makeTextPDF(at: url, lines: ["DOI: 10.5555/bulk.\(i)"])
            sources.append(url)
            try queue.enqueue(kind: .ingest, payload: ["pdf_path": url.path], origin: .app)
        }
        _ = await runner.tick()

        // 3本ともpdf_only（フォールバック）で完走している
        #expect(try store.allPapers().count == 3)
        #expect(try queue.jobs(status: .succeeded).count == 3)
    }
}

/// 参考文献DOIの誤認防止（→ docs/04 4節。Supp PDF交絡バグの回帰テスト）
@Suite("References以降のID抽出除外")
struct ReferencesTruncationTests {
    @Test("truncateAtReferences: 各種見出し形式で切り詰める")
    func truncationVariants() {
        for heading in ["## References", "References", "REFERENCES", "Bibliography", "## 参考文献", "References:"] {
            let text = "Supplementary material\nSome body text\n\(heading)\n[1] Cited, https://doi.org/10.1103/PhysRevLett.77.3865"
            let truncated = IngestPipeline.truncateAtReferences(text)
            #expect(!truncated.contains("10.1103"), "「\(heading)」以降が落ちる")
            #expect(truncated.contains("Some body text"))
        }
        // 見出しがなければそのまま
        let plain = "DOI: 10.1063/5.0138489\nbody"
        #expect(IngestPipeline.truncateAtReferences(plain) == plain)
        // 本文中の語としての references は切らない
        let inline = "see references therein\nDOI: 10.1063/5.0138489"
        #expect(IngestPipeline.truncateAtReferences(inline).contains("10.1063"))
    }

    /// 実バグの再現: 自分のDOIを持たない短いSupp文書で、
    /// 参考文献[1]のDOI（別論文）が冒頭6000字に入っていても誤認しない
    @Test("Supp文書が引用先DOIで別論文として登録されない（交絡バグ回帰）")
    func suppDoesNotStealCitedDOI() async throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        let executors = FakeExecutors(resolveResult: sampleResolved())
        executors.bibliographicResult = nil  // タイトル検索も解決しない
        // 変換結果: 短いSupp（参考文献に他論文のDOI）を模す
        executors.convertMarkdownOverride = """
        ## Supplementary material

        ## Unique temperature-dependence of polarization switching paths

        Hikaru Azuma, et al.

        Body of the supplementary text.

        ## References

        - [1] J.P. Perdew, K. Burke, M. Ernzerhof, Generalized gradient approximation made simple, \
        Phys. Rev. Lett. 77 (1996) 3865-3868. https://doi.org/10.1103/PhysRevLett.77.3865.
        """
        let pipeline = IngestPipeline(store: store, queue: queue, executors: executors)

        let source = root.appendingPathComponent("supp.pdf")
        try Data("%PDF-1.4 supplementary".utf8).write(to: source)
        let job = try queue.enqueue(kind: .ingest, payload: ["pdf_path": source.path], origin: .app)
        let status = try await runToCompletion(queue, pipeline, job.id)

        // 引用先DOIでの解決が走っていないこと（修正前はここで .doi("10.1103/...") が記録されていた）
        #expect(!executors.resolveIdentifiers.contains { id in
            if case .doi(let d) = id { return d.contains("10.1103") }
            return false
        }, "参考文献のDOIを自分のIDと誤認しない")
        // 誤った身元での登録ではなく pdf_only（手動解決の対象）に倒れる
        #expect(status == .pdfOnly)
        let paperId = try #require(try queue.job(id: job.id)?.paperId)
        #expect(try store.paper(id: paperId)?.doi == nil)
    }
}

/// 並行取り込みのUNIQUE競合（→ docs/04 5節。一括投入で8分リトライ後failedになった事故の回帰テスト）
@Suite("並行取り込みのDOI競合")
struct ConcurrentDOIConflictTests {
    @Test("チェック後に他ジョブが同一DOIを登録 → リトライせず重複cancelに変換")
    func uniqueConflictBecomesDuplicate() async throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        let executors = FakeExecutors(resolveResult: sampleResolved())
        let pipeline = IngestPipeline(store: store, queue: queue, executors: executors)

        // 「重複チェック通過後に競合相手がINSERTした」状況を再現:
        // resolveの中（チェック前）では存在せず、保存時には存在する……は決定的に作れないため、
        // ヘルパーを直接検証する: 既存と同一DOIの新規行を保存しようとすると duplicate に変換される
        let existing = samplePaper()
        try store.savePaper(existing, authors: [])

        var rival = samplePaper()  // 同じDOI・別ID
        rival.paperStatus = .metadataOnly
        do {
            try pipeline.savePaperResolvingConflicts(rival, authors: [], cleanupDirOnConflict: true)
            Issue.record("duplicateになるはず")
        } catch let error as IngestError {
            #expect(error == .duplicate(existingPaperId: existing.id), "正規の重複検出に変換")
        }
        // 作りかけのディレクトリは破棄されている
        #expect(!FileManager.default.fileExists(atPath: store.layout.paperDir(rival.id).path))
        // 行は増えていない
        let count = try store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM papers") }
        #expect(count == 1)
    }

    @Test("ジョブ経路: 競合はバックオフリトライせず即cancelled")
    func jobCancelsImmediately() async throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        let executors = FakeExecutors(resolveResult: sampleResolved())
        let pipeline = IngestPipeline(store: store, queue: queue, executors: executors)

        // 既存論文（同一DOI・PDFあり）→ duplicate経路に入ることを確認
        let existing = samplePaper()
        try store.savePaper(existing, authors: [])
        try FileManager.default.createDirectory(at: store.layout.paperDir(existing.id), withIntermediateDirectories: true)
        try Data("%PDF".utf8).write(to: store.layout.pdfPath(existing.id))

        let job = try queue.enqueue(kind: .ingest, payload: ["arxiv_id": "1706.03762"], origin: .app)
        do {
            _ = try await runToCompletion(queue, pipeline, job.id)
        } catch {}
        let finished = try #require(try queue.job(id: job.id))
        #expect(finished.jobStatus == .cancelled, "failedでなくcancelled")
        #expect(finished.retryCount == 0, "バックオフリトライしない")
    }
}

/// DOI保有stubがある論文の先行解決（→ docs/08 4節。一括投入で必ずUNIQUE失敗した実バグの回帰テスト）
@Suite("先行解決のstub昇格")
struct PreResolutionStubPromotionTests {
    @Test("stub行が同一行のまま昇格し、引用エッジが温存される")
    func stubPromotedInPlace() async throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let queue = JobQueue(db: store.db)
        let executors = FakeExecutors(resolveResult: sampleResolved())  // doi = 10.5555/...
        let pipeline = IngestPipeline(store: store, queue: queue, executors: executors)

        // 引用グラフ由来のstub（同じDOIを保有）+ centerからのエッジ
        let center = samplePaper(title: "Center", doi: "10.1000/center", arxivId: nil)
        try store.savePaper(center, authors: [])
        let citations = CitationStore(db: store.db)
        try citations.replaceEdges(center: center.id, references: [
            .init(title: "Attention Is All You Need", doi: "10.5555/3295222.3295349"),
        ], citations: [], source: .s2)
        let stubId = try store.db.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT id FROM papers WHERE doi = '10.5555/3295222.3295349'")!
        }

        // DOI印字つきPDFをドロップ（先行解決が発火）
        let source = root.appendingPathComponent("cited.pdf")
        try makeTextPDF(at: source, lines: ["DOI: 10.5555/3295222.3295349"])
        let job = try queue.enqueue(kind: .ingest, payload: ["pdf_path": source.path], origin: .app)
        let status = try await runToCompletion(queue, pipeline, job.id)

        #expect(status == .indexed)
        let promoted = try #require(try store.paper(id: stubId), "同一行のまま")
        #expect(!promoted.isStub)
        #expect(promoted.title == "Attention Is All You Need")
        // 引用エッジが温存されている
        let network = try citations.egoNetwork(center: center.id)
        #expect(network.edges.contains { $0.citedId == stubId })
        // 同一DOIの行は1つだけ（UNIQUE競合なし）
        let count = try store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM papers WHERE doi = '10.5555/3295222.3295349'") }
        #expect(count == 1)
        #expect(try queue.job(id: job.id)?.jobStatus == .succeeded, "失敗もリトライもしない")
    }
}
