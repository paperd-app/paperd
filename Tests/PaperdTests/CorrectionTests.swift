import Foundation
import Testing
import PaperdCore
import PaperdMCPKit

@Suite("ConversionQualityChecker")
struct ConversionQualityCheckerTests {
    let checker = ConversionQualityChecker()

    @Test("正常なテキストは警告なし")
    func cleanText() {
        let warnings = checker.scan("# Title\n\nNormal academic text with 10^3 angstrom and core-shell potential.")
        #expect(warnings.isEmpty)
    }

    @Test("(cid:NNN)の検出")
    func cidReferences() {
        let warnings = checker.scan("the value (cid:31)(cid:32) was measured")
        #expect(warnings.count == 1)
        #expect(warnings[0].kind == .cidReference)
        #expect(warnings[0].count == 2)
    }

    @Test("分数グリフの誤対応検出（≈→¼等。複数回出現で警告）")
    func suspiciousFractions() {
        // 1回だけなら正当な分数の可能性があるため警告しない
        #expect(checker.scan("add ¼ cup of water").isEmpty)
        // 散在する場合はToUnicode CMap破損の兆候
        let warnings = checker.scan("velocity ¼ 100 m/s and length ¼ 5 nm and T ¾ 300 K")
        #expect(warnings.count == 1)
        #expect(warnings[0].kind == .suspiciousFraction)
        #expect(warnings[0].count == 3)
    }

    @Test("置換文字・私用領域・合字の検出")
    func otherGarbling() {
        let warnings = checker.scan("br\u{FFFD}ken \u{E001} \u{FB01}eld")  // � PUA ﬁ
        let kinds = Set(warnings.map(\.kind))
        #expect(kinds == [.replacementChar, .privateUseArea, .unnormalizedLigature])
    }

    @Test("キリル同形字の検出（ラテン主体の文書のみ）")
    func cyrillicHomoglyphs() {
        // OCRがPbTiO3をキリル文字で読んだ実例（force_ocr使用時に発生）
        let warnings = checker.scan("Ti at the B-site of \u{0420}\u{042C}\u{0422}\u{0456}\u{041E}\u{0437} (PT) is partially replaced by Zr in the lattice structure of the material")
        #expect(warnings.contains { $0.kind == .cyrillicHomoglyph && $0.count == 6 })
        // キリル主体の文書（ロシア語文献）は対象外
        #expect(checker.scan("Это статья о физике твёрдого тела и сегнетоэлектриках").isEmpty)
    }

    @Test("総警告数")
    func totalCount() {
        #expect(checker.totalWarningCount("x ¼ 1, y ¼ 2, (cid:7)") == 3)
        #expect(checker.totalWarningCount("clean text") == 0)
    }
}

@Suite("FulltextCorrector")
struct FulltextCorrectorTests {
    func setupPaper() throws -> (LibraryStore, URL, Paper, FulltextCorrector) {
        let (store, root) = try makeTempLibrary()
        let paper = samplePaper()
        try store.savePaper(paper, authors: [])
        try Data("# Title\n\nThe length is 103 Å in the simulation.\nThe approx value is ¼ 5.".utf8)
            .write(to: store.layout.markdownPath(paper.id))
        return (store, root, paper, FulltextCorrector(layout: store.layout))
    }

    @Test("パッチ適用: corrected.md作成・原本不変・履歴記録")
    func applyPatches() throws {
        let (store, root, paper, corrector) = try setupPaper()
        defer { cleanup(root) }

        let result = try corrector.apply(
            paperId: paper.id,
            patches: [
                .init(find: "103 Å", replace: "10³ Å"),
                .init(find: "approx value is ¼ 5", replace: "approx value is ≈ 5"),
            ],
            note: "PDF p.3と照合"
        )
        #expect(result.contains("10³ Å"))
        #expect(result.contains("≈ 5"))

        // 有効Markdownは修正版
        #expect(corrector.effectiveMarkdown(paperId: paper.id) == result)
        #expect(corrector.hasCorrections(paperId: paper.id))
        // 原本（Docling出力）は不変
        let original = String(data: FileManager.default.contents(atPath: store.layout.markdownPath(paper.id).path)!, encoding: .utf8)!
        #expect(original.contains("103 Å"))
        // 履歴
        let log = corrector.log(paperId: paper.id)
        #expect(log.entries.count == 1)
        #expect(log.entries[0].note == "PDF p.3と照合")
        #expect(log.entries[0].patches.count == 2)
    }

    @Test("findが見つからない場合は1件も適用しない")
    func notFoundAbortsAll() throws {
        let (_, root, paper, corrector) = try setupPaper()
        defer { cleanup(root) }
        #expect(throws: FulltextCorrector.PatchError.findNotFound(index: 1, find: "存在しないテキスト")) {
            try corrector.apply(paperId: paper.id, patches: [
                .init(find: "103 Å", replace: "10³ Å"),
                .init(find: "存在しないテキスト", replace: "x"),
            ])
        }
        #expect(!corrector.hasCorrections(paperId: paper.id), "部分適用されていない")
    }

    @Test("findが曖昧（複数回出現）はエラー")
    func ambiguousFind() throws {
        let (_, root, paper, corrector) = try setupPaper()
        defer { cleanup(root) }
        #expect(throws: FulltextCorrector.PatchError.findAmbiguous(index: 0, find: "is", occurrences: 2)) {
            try corrector.apply(paperId: paper.id, patches: [.init(find: "is", replace: "was")])
        }
    }

    @Test("2回目の修正は前回の修正版に積み重なる")
    func incrementalCorrections() throws {
        let (_, root, paper, corrector) = try setupPaper()
        defer { cleanup(root) }
        try corrector.apply(paperId: paper.id, patches: [.init(find: "103 Å", replace: "10³ Å")])
        try corrector.apply(paperId: paper.id, patches: [.init(find: "¼ 5", replace: "≈ 5")])
        let effective = try #require(corrector.effectiveMarkdown(paperId: paper.id))
        #expect(effective.contains("10³ Å") && effective.contains("≈ 5"))
        #expect(corrector.log(paperId: paper.id).entries.count == 2)
    }

    @Test("revertでDocling出力へ戻る")
    func revert() throws {
        let (_, root, paper, corrector) = try setupPaper()
        defer { cleanup(root) }
        try corrector.apply(paperId: paper.id, patches: [.init(find: "103 Å", replace: "10³ Å")])
        try corrector.revert(paperId: paper.id)
        #expect(!corrector.hasCorrections(paperId: paper.id))
        let effective = try #require(corrector.effectiveMarkdown(paperId: paper.id))
        #expect(effective.contains("103 Å"), "原本に戻る")
    }
}

@Suite("修正・再変換ジョブ")
struct CorrectionJobTests {
    func makePipeline() throws -> (LibraryStore, URL, JobQueue, FakeExecutors, IngestPipeline) {
        let (store, root) = try makeTempLibrary()
        let queue = JobQueue(db: store.db)
        let executors = FakeExecutors(resolveResult: sampleResolved())
        let pipeline = IngestPipeline(store: store, queue: queue, executors: executors)
        return (store, root, queue, executors, pipeline)
    }

    /// 取り込み済み論文を1件用意する
    func ingestOne(_ queue: JobQueue, _ pipeline: IngestPipeline) async throws -> String {
        let job = try queue.enqueue(kind: .ingest, payload: ["arxiv_id": "1706.03762"], origin: .app)
        _ = try await runToCompletion(queue, pipeline, job.id)
        return try #require(try queue.job(id: job.id)?.paperId)
    }

    @Test("reindex: 修正版MarkdownがRAGインデックスへ反映される")
    func reindexUsesCorrectedMarkdown() async throws {
        let (store, root, queue, _, pipeline) = try makePipeline()
        defer { cleanup(root) }
        let paperId = try await ingestOne(queue, pipeline)

        // 修正を適用（FTSに乗る独自語を含める）。FakeExecutorsのpaper.mdの本文に対するパッチ
        let corrector = FulltextCorrector(layout: store.layout)
        try corrector.apply(paperId: paperId, patches: [
            .init(find: "We study transformer attention.", replace: "We study transformer attention (corrected supercalifragilistic)."),
        ])

        let job = try queue.enqueue(kind: .reindex, paperId: paperId, payload: [:], origin: .mcp)
        _ = try queue.claim(job.id)
        _ = try await pipeline.runReindex(job: try #require(try queue.job(id: job.id)))
        #expect(try queue.job(id: job.id)?.jobStatus == .succeeded)

        let search = HybridSearch(db: store.db)
        let (results, _) = try await search.search(query: "supercalifragilistic", topK: 5, embedder: nil)
        #expect(results.contains { $0.paperId == paperId }, "修正後の本文がFTSにヒット")
    }

    @Test("reconvert: 高精度オプションでconvertが再実行される")
    func reconvertUsesHighQualityOptions() async throws {
        let (store, root, queue, executors, pipeline) = try makePipeline()
        defer { cleanup(root) }
        let paperId = try await ingestOne(queue, pipeline)
        try #require(executors.convertOptions.count == 1)
        #expect(executors.convertOptions[0] == WorkerClient.ConvertOptions())

        let job = try queue.enqueue(kind: .reconvert, paperId: paperId, payload: [:], origin: .app)
        _ = try queue.claim(job.id)
        let status = try await pipeline.runReconvert(job: try #require(try queue.job(id: job.id)))
        #expect(status == .indexed)
        try #require(executors.convertOptions.count == 2)
        #expect(executors.convertOptions[1] == .highQuality, "force_ocr + formula_enrichment")
        #expect(executors.convertOptions[1].forceOcr)
        #expect(try store.paper(id: paperId)?.paperStatus == .indexed)
    }

    @Test("reconvert: 既存のcorrected.mdは破棄され、新しい変換結果が有効になる")
    func reconvertSupersedesCorrections() async throws {
        let (store, root, queue, _, pipeline) = try makePipeline()
        defer { cleanup(root) }
        let paperId = try await ingestOne(queue, pipeline)

        // 旧本文に対する修正を適用
        let corrector = FulltextCorrector(layout: store.layout)
        try corrector.apply(paperId: paperId, patches: [
            .init(find: "We study transformer attention.", replace: "OLD CORRECTION"),
        ])
        #expect(corrector.hasCorrections(paperId: paperId))

        // 高精度再変換 → corrected.mdは破棄され、履歴に記録される
        let job = try queue.enqueue(kind: .reconvert, paperId: paperId, payload: [:], origin: .app)
        _ = try queue.claim(job.id)
        _ = try await pipeline.runReconvert(job: try #require(try queue.job(id: job.id)))

        #expect(!corrector.hasCorrections(paperId: paperId), "corrected.mdは破棄")
        let effective = try #require(corrector.effectiveMarkdown(paperId: paperId))
        #expect(!effective.contains("OLD CORRECTION"), "新しい変換結果が有効")
        let log = corrector.log(paperId: paperId)
        #expect(log.entries.last?.note?.contains("reconvert") == true, "破棄理由が履歴に残る")

        // RAGインデックスも新しい本文から再構築されている
        let search = HybridSearch(db: store.db)
        let (results, _) = try await search.search(query: "OLD CORRECTION", topK: 5, embedder: nil)
        #expect(results.isEmpty, "旧修正はインデックスから消える")
    }

    @Test("reconvert: 後段failed後のリトライは再変換をスキップして再開する")
    func reconvertResumesAfterLaterStageFailure() async throws {
        let (store, root, queue, executors, pipeline) = try makePipeline()
        defer { cleanup(root) }
        let paperId = try await ingestOne(queue, pipeline)
        let convertsAfterIngest = executors.convertCalls

        // embedで一時失敗させる
        let job = try queue.enqueue(kind: .reconvert, paperId: paperId, payload: [:], origin: .app)
        _ = try queue.claim(job.id)
        executors.embedError = FakeExecutors.TransientError()
        await #expect(throws: (any Error).self) {
            _ = try await pipeline.runReconvert(job: try #require(try queue.job(id: job.id)))
        }
        #expect(try queue.job(id: job.id)?.jobStatus == .queued, "バックオフ付きリトライ")
        #expect(executors.convertCalls == convertsAfterIngest + 1)

        // 復旧してリトライ → convertは再実行されない（stage=convert済みから再開）
        executors.embedError = nil
        _ = try queue.claim(job.id)
        let status = try await pipeline.runReconvert(job: try #require(try queue.job(id: job.id)))
        #expect(status == .indexed)
        #expect(executors.convertCalls == convertsAfterIngest + 1, "高コストな再変換はスキップ")
    }

    @Test("reconvert: PDFなしは恒久的エラー")
    func reconvertWithoutPDF() async throws {
        let (store, root, queue, executors, pipeline) = try makePipeline()
        defer { cleanup(root) }
        executors.fetchSucceeds = false
        let paperId = try await ingestOne(queue, pipeline)  // metadata_only（PDFなし）

        let job = try queue.enqueue(kind: .reconvert, paperId: paperId, payload: [:], origin: .app)
        _ = try queue.claim(job.id)
        await #expect(throws: (any Error).self) {
            _ = try await pipeline.runReconvert(job: try #require(try queue.job(id: job.id)))
        }
        #expect(try queue.job(id: job.id)?.jobStatus == .failed)
        #expect(try store.paper(id: paperId)?.paperStatus == .metadataOnly, "論文状態は変わらない")
    }

    @Test("conversion_warningsがchunk時に計算・保存される")
    func warningsComputedDuringIngest() async throws {
        let (store, root, queue, executors, pipeline) = try makePipeline()
        defer { cleanup(root) }
        _ = executors  // FakeExecutorsのpaper.mdはクリーン → 0
        let paperId = try await ingestOne(queue, pipeline)
        #expect(try store.paper(id: paperId)?.conversionWarnings == 0)

        // 文字化けを含むpaper.mdに差し替えてreindex → 警告数が更新される
        try Data("x ¼ 1 and y ¼ 2 and (cid:3)".utf8).write(to: store.layout.markdownPath(paperId))
        let job = try queue.enqueue(kind: .reindex, paperId: paperId, payload: [:], origin: .app)
        _ = try queue.claim(job.id)
        _ = try await pipeline.runReindex(job: try #require(try queue.job(id: job.id)))
        #expect(try store.paper(id: paperId)?.conversionWarnings == 3)
    }

    @Test("JobRunner.tick: reindex/reconvertジョブが正しいハンドラへディスパッチされる")
    func jobRunnerDispatchesMaintenanceJobs() async throws {
        let (store, root, queue, executors, pipeline) = try makePipeline()
        defer { cleanup(root) }
        let paperId = try await ingestOne(queue, pipeline)
        let resolveCallsAfterIngest = executors.resolveCalls

        let runner = JobRunner(queue: queue, pipeline: pipeline)
        try queue.enqueue(kind: .reindex, paperId: paperId, payload: [:], origin: .mcp)
        try queue.enqueue(kind: .reconvert, paperId: paperId, payload: [:], origin: .app)
        let processed = await runner.tick()
        #expect(processed == 2)
        #expect(executors.resolveCalls == resolveCallsAfterIngest, "resolveが呼ばれていない（ingest経路に流れていない）")

        let jobs = try queue.jobs()
        for job in jobs where job.kind != "ingest" {
            #expect(job.jobStatus == .succeeded, "\(job.kind): \(job.lastError ?? "-")")
        }
    }

    @Test("MarkdownChunkSource: 修正版Markdownからセクション構造つきでチャンク化")
    func markdownChunkSource() {
        let md = """
        ## 3. Method

        We use attention.

        | A | B |
        |---|---|
        | 1 | 2 |
        """
        let items = MarkdownChunkSource.items(fromMarkdown: md)
        #expect(items.count == 3)
        #expect(items[0].kind == .sectionHeader(level: 2))
        #expect(items[2].kind == .table)
        let pieces = Chunker().chunk(items: items)
        #expect(pieces.allSatisfy { $0.sectionPath == "3. Method" })
    }
}

@Suite("MCP apply_fulltext_patches")
struct MCPCorrectionTests {
    func makeServer() throws -> (MCPServer, LibraryStore, URL, Paper) {
        let (store, root) = try makeTempLibrary()
        let paper = samplePaper()
        try store.savePaper(paper, authors: [])
        try Data("# Paper\n\nThe length is 103 Å here.".utf8).write(to: store.layout.markdownPath(paper.id))
        let tools = PaperdTools(
            store: store,
            embedderProvider: { nil },
            resolver: { _ in sampleResolved() }
        )
        return (MCPServer(tools: tools), store, root, paper)
    }

    func call(_ server: MCPServer, args: [String: JSONValue]) async throws -> (text: String, isError: Bool) {
        let request = JSONRPCRequest(
            id: .number(1), method: "tools/call",
            params: .object(["name": .string("apply_fulltext_patches"), "arguments": .object(args)]))
        let response = try #require(await server.handle(request: request))
        let result = try #require(response.result)
        guard case .array(let items)? = result["content"], case .object(let first)? = items.first,
              case .string(let text)? = first["text"] else { throw MCPTests.TestError("content形式") }
        var isError = false
        if case .bool(let e)? = result["isError"] { isError = e }
        return (text, isError)
    }

    @Test("パッチ適用 + reindexジョブ投入 + get_fulltextが修正版を返す")
    func applyAndReindex() async throws {
        let (server, store, root, paper) = try makeServer()
        defer { cleanup(root) }
        let (text, isError) = try await call(server, args: [
            "paper_id": .string(paper.id),
            "patches": .array([.object(["find": .string("103 Å"), "replace": .string("10³ Å")])]),
            "note": .string("PDFと照合済み"),
        ])
        #expect(!isError, Comment(rawValue: text))
        #expect(text.contains("\"applied\" : 1"), Comment(rawValue: text))

        // reindexジョブがmcp起源で入る
        let jobs = try JobQueue(db: store.db).jobs(status: .queued)
        try #require(jobs.count == 1)
        #expect(jobs[0].kind == "reindex")
        #expect(jobs[0].origin == "mcp")
        #expect(jobs[0].paperId == paper.id)

        // get_fulltextは修正版（有効Markdown）を返す
        let fulltextRequest = JSONRPCRequest(
            id: .number(2), method: "tools/call",
            params: .object(["name": .string("get_fulltext"),
                             "arguments": .object(["paper_id": .string(paper.id)])]))
        let response = try #require(await server.handle(request: fulltextRequest))
        guard case .array(let items)? = response.result?["content"], case .object(let first)? = items.first,
              case .string(let fulltext)? = first["text"] else { throw MCPTests.TestError("content形式") }
        #expect(fulltext.contains("10³ Å"))
    }

    @Test("曖昧・不在のfindはエラーで何も書き込まない")
    func invalidPatchesRejected() async throws {
        let (server, store, root, paper) = try makeServer()
        defer { cleanup(root) }
        let (text, isError) = try await call(server, args: [
            "paper_id": .string(paper.id),
            "patches": .array([.object(["find": .string("not in the text"), "replace": .string("x")])]),
        ])
        #expect(isError)
        #expect(text.contains("not found"), Comment(rawValue: text))
        #expect(!FulltextCorrector(layout: store.layout).hasCorrections(paperId: paper.id))
        #expect(try JobQueue(db: store.db).jobs(status: .queued).isEmpty, "ジョブも投入されない")
    }

    @Test("get_paper_metadataにpdf_path/markdown_path/has_correctionsが含まれる")
    func metadataIncludesPaths() async throws {
        let (server, store, root, paper) = try makeServer()
        defer { cleanup(root) }
        try Data("%PDF-1.4".utf8).write(to: store.layout.pdfPath(paper.id))

        let request = JSONRPCRequest(
            id: .number(3), method: "tools/call",
            params: .object(["name": .string("get_paper_metadata"),
                             "arguments": .object(["paper_id": .string(paper.id)])]))
        let response = try #require(await server.handle(request: request))
        guard case .array(let items)? = response.result?["content"], case .object(let first)? = items.first,
              case .string(let text)? = first["text"] else { throw MCPTests.TestError("content形式") }
        let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect((json["pdf_path"] as? String)?.hasSuffix("paper.pdf") == true)
        #expect((json["markdown_path"] as? String)?.hasSuffix("paper.md") == true)
        #expect(json["has_corrections"] as? Bool == false)
    }
}

/// 修正版のsection取得（→ docs/07 2.3節。MCP経由で旧本文が読まれた実バグの回帰テスト）
@Suite("修正版のセクション取得")
struct CorrectedSectionTests {
    @Test("extractSection: 見出し抽出とsection_path形式の照合")
    func extraction() {
        let markdown = """
        # Title

        intro text

        ## 2. Methods

        corrected method text

        ### 2.1 Details

        detail text

        ## 3. Results

        results text
        """
        let methods = FulltextCorrector.extractSection(markdown: markdown, section: "2. Methods")
        #expect(methods?.contains("corrected method text") == true)
        #expect(methods?.contains("detail text") == true, "下位見出しは含む")
        #expect(methods?.contains("results text") == false, "同レベルの次見出しで切れる")
        // section_path形式（"親 > 子"）は最後の要素で照合
        let details = FulltextCorrector.extractSection(markdown: markdown, section: "2. Methods > 2.1 Details")
        #expect(details?.contains("detail text") == true)
        #expect(FulltextCorrector.extractSection(markdown: markdown, section: "存在しない") == nil)
    }

    @Test("get_fulltext(section): 修正後はreindex前でも修正版が返る")
    func sectionReturnsCorrectedBeforeReindex() async throws {
        let (store, root) = try makeTempLibrary()
        defer { cleanup(root) }
        let paper = samplePaper()
        try store.savePaper(paper, authors: [])
        // 旧本文でチャンク索引を作る（reindex前の状態を再現）
        try FileManager.default.createDirectory(at: store.layout.paperDir(paper.id), withIntermediateDirectories: true)
        try Data("## 2. Methods\n\nbroken 103 A text".utf8).write(to: store.layout.markdownPath(paper.id))
        try SearchIndex(db: store.db).indexPaper(paperId: paper.id, pieces: [
            Chunker.Piece(sectionPath: "2. Methods", text: "broken 103 A text", tokenCount: 4),
        ])
        // 修正を適用（corrected.md + reindexジョブが立つ。チャンクは反映待ちで旧のまま）
        let tools = PaperdTools(store: store, embedderProvider: { nil }, resolver: { _ in sampleResolved() })
        let applied = await tools.call(name: "apply_fulltext_patches", arguments: [
            "paper_id": .string(paper.id),
            "patches": .array([.object(["find": .string("broken 103 A text"), "replace": .string("fixed 10^3 Å text")])]),
        ])
        #expect(!applied.isError, Comment(rawValue: applied.text))

        let result = await tools.call(name: "get_fulltext", arguments: [
            "paper_id": .string(paper.id), "section": .string("2. Methods"),
        ])
        #expect(!result.isError)
        #expect(result.text.contains("fixed 10^3 Å text"), "修正版が返る: \(result.text)")
        #expect(!result.text.contains("broken 103 A text"), "旧チャンクを返さない")
        #expect(result.text.contains("not yet caught up"), "反映待ちの注記つき")

        // 抽出不能なセクション名 → 旧チャンクに警告ヘッダ
        let fallback = await tools.call(name: "get_fulltext", arguments: [
            "paper_id": .string(paper.id), "section": .string("2. Methods > 存在しない小節"),
        ])
        if !fallback.isError {
            #expect(fallback.text.hasPrefix("⚠"), "旧チャンク応答には必ず警告: \(fallback.text.prefix(40))")
        }
    }
}
