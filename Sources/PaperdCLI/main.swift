import Foundation
import PaperdCore

// paperd-cli: ヘッドレス運用・E2E検証用の管理CLI。
// アプリ（GUI）を起動せずにジョブの確認・再試行・実行、検索の動作確認ができる。
//
//   paperd-cli jobs                 ジョブ一覧
//   paperd-cli papers               論文一覧
//   paperd-cli add <input>          取り込みジョブ投入（arXiv ID / DOI / URL / PDFパス）
//   paperd-cli retry-failed         失敗ジョブをすべてqueuedへ戻す
//   paperd-cli process              キューが空になるまでジョブを実行（実ワーカー使用）
//   paperd-cli search <query>       ハイブリッド検索（ワーカーが生きていればsemantic併用）
//
// 環境変数: PAPERD_LIBRARY / PAPERD_MAILTO / PAPERD_S2_API_KEY
// worker パスは WorkerLocator が自動解決（→ docs/01 3.3節）

let env = ProcessInfo.processInfo.environment
let libraryRoot = env["PAPERD_LIBRARY"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    ?? LibraryLayout.defaultRoot

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print("usage: paperd-cli <jobs|papers|add|retry-failed|process|search> [args]")
    exit(64)
}

let store: LibraryStore
do {
    store = try LibraryStore.open(at: libraryRoot)
} catch {
    fail("\(error)")
}
let queue = JobQueue(db: store.db)

func makeRunner() -> JobRunner {
    let mailto = env["PAPERD_MAILTO"]
    let s2Key = env["PAPERD_S2_API_KEY"]
    let resolver = MetadataResolver.live(mailto: mailto, s2APIKey: s2Key)
    // 起動時に 1 回だけ workerDir を解決（必要なら配布バンドルから展開）
    let workerDir: URL? = (try? WorkerLocator.locateOrDeploy()) ?? WorkerLocator.locate()
    let executors = LiveStageExecutors(resolver: resolver, unpaywallEmail: mailto) {
        // 必ずバージョン照合を通す（旧ワーカー残留時は自動で入れ替え → docs/01 3.2節）
        if let workerDir {
            return try await WorkerProcessManager(workerDirectory: workerDir).startOrReuseVerified()
        }
        if let client = WorkerLock.reusableClient() {
            if let health = try? await client.health(), health.version == WorkerClient.expectedWorkerVersion {
                return client
            }
            throw WorkerClient.WorkerAPIError(
                code: "MODEL_NOT_READY",
                message: "The running worker is an outdated version and no worker source is reachable to replace it.",
                statusCode: 0)
        }
        throw WorkerClient.WorkerAPIError(
            code: "MODEL_NOT_READY",
            message: "Worker is not running and no worker source is reachable. Run setup from the app's Settings > Worker.",
            statusCode: 0)
    }
    let pipeline = IngestPipeline(store: store, queue: queue, executors: executors)
    let fetcher = CitationFetcher(
        db: store.db,
        s2: SemanticScholarClient(http: URLSessionHTTPClient(), apiKey: env["PAPERD_S2_API_KEY"]),
        openAlex: OpenAlexClient(http: URLSessionHTTPClient(), mailto: env["PAPERD_MAILTO"]))
    return JobRunner(queue: queue, pipeline: pipeline, citationFetcher: fetcher)
}

switch command {
case "jobs":
    for job in try queue.jobs() {
        let error = job.lastError.map { " error=\($0.prefix(120))" } ?? ""
        print("\(job.id.prefix(8))  \(job.kind)\t\(job.status)\tstage=\(job.stage ?? "-")\tretry=\(job.retryCount)\(error)")
    }

case "papers":
    for paper in try store.allPapers() {
        print("\(paper.id.prefix(8))  [\(paper.status)]\t\(paper.title.prefix(70))")
    }

case "add":
    guard arguments.count >= 2 else { fail("add <arXiv ID | DOI | URL | PDF path | folder>") }
    let input = (arguments[1] as NSString).expandingTildeInPath
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: input, isDirectory: &isDirectory),
       isDirectory.boolValue || input.lowercased().hasSuffix(".pdf") {
        // フォルダは再帰走査して一括投入（→ docs/09 7節）
        let pdfs = PDFImportScanner.pdfs(in: [URL(fileURLWithPath: input)])
        guard !pdfs.isEmpty else { fail("no PDFs found: \(input)") }
        for pdf in pdfs {
            try queue.enqueue(kind: .ingest, payload: ["pdf_path": pdf.path], origin: .app)
        }
        print("queued: \(pdfs.count) PDF(s)")
    } else if PaperIdentifier.parse(arguments[1]) != nil {
        let job = try queue.enqueue(kind: .ingest, payload: ["input": arguments[1]], origin: .app)
        print("queued: \(job.id)")
    } else {
        fail("cannot parse input: \(arguments[1])")
    }

case "markdown":
    // paper.mdのブロック分解結果を確認（変換ミス調査用 → docs/09 4節 Markdownタブと同じパーサ）
    guard arguments.count >= 2 else { fail("markdown <paper-id (prefix match allowed)>") }
    let prefix = arguments[1]
    guard let paper = try store.allPapers().first(where: { $0.id.hasPrefix(prefix) }) else {
        fail("no paper matches paper-id \(prefix)")
    }
    guard let data = FileManager.default.contents(atPath: store.layout.markdownPath(paper.id).path),
          let markdown = String(data: data, encoding: .utf8)
    else { fail("paper.md not found") }
    let blocks = MarkdownBlockParser.parse(markdown)
    var counts: [String: Int] = [:]
    for block in blocks {
        let key: String
        switch block {
        case .heading: key = "heading"
        case .paragraph: key = "paragraph"
        case .list: key = "list"
        case .table: key = "table"
        case .codeBlock: key = "code"
        case .imagePlaceholder: key = "image"
        case .horizontalRule: key = "rule"
        }
        counts[key, default: 0] += 1
    }
    print("blocks: \(blocks.count)  \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
    for block in blocks.prefix(12) {
        switch block {
        case .heading(let level, let text): print("H\(level): \(text.prefix(70))")
        case .paragraph(let text): print("P:  \(text.prefix(70))")
        case .list(let items, _): print("L:  \(items.count) items: \(items.first?.prefix(50) ?? "")")
        case .table(let header, let rows): print("T:  \(header.count) cols × \(rows.count) rows: \(header.joined(separator: " | ").prefix(60))")
        case .codeBlock: print("C:  (code)")
        case .imagePlaceholder: print("IMG")
        case .horizontalRule: print("---")
        }
    }

case "resolve":
    // pdf_only論文の再解決（手動解決UI相当 → docs/04 4節）。
    // 既存paper行を保持したままローカルPDF解決パイプラインを再実行する
    guard arguments.count >= 2 else { fail("resolve <paper-id (prefix match allowed)>") }
    let prefix = arguments[1]
    let papers = try store.allPapers().filter { $0.id.hasPrefix(prefix) }
    guard papers.count == 1, let paper = papers.first else {
        fail("\(papers.isEmpty ? "no papers match" : "multiple papers match") paper-id \(prefix)")
    }
    let pdfPath = store.layout.pdfPath(paper.id).path
    guard FileManager.default.fileExists(atPath: pdfPath) else {
        fail("paper.pdf not found: \(pdfPath)")
    }
    let job = try queue.enqueue(
        kind: .ingest, paperId: paper.id, payload: ["pdf_path": pdfPath], origin: .app)
    print("queued: \(job.id) (re-resolving \(paper.title.prefix(50)))")

case "attach":
    // PDF未取得の論文へPDFを添付し、convert以降を再開する（→ docs/04 6節）
    guard arguments.count >= 3 else { fail("attach <paper-id (prefix match allowed)> <PDF path>") }
    let prefix = arguments[1]
    let pdfPath = (arguments[2] as NSString).expandingTildeInPath
    guard let paper = try store.allPapers().first(where: { $0.id.hasPrefix(prefix) }) else {
        fail("no paper matches paper-id \(prefix)")
    }
    guard FileManager.default.fileExists(atPath: pdfPath) else { fail("PDF not found: \(pdfPath)") }
    try store.attachPDF(paperId: paper.id, from: URL(fileURLWithPath: pdfPath))
    let job = try queue.enqueue(kind: .ingest, paperId: paper.id, payload: [:], origin: .app, completedStage: .fetch)
    print("attached + queued: \(job.id) (resuming from convert for \(paper.title.prefix(50)))")

case "fix-titles":
    // 既存データのタイトル・誌名マークアップを一括修復（→ docs/04 3節）
    var fixed = 0
    let all = try store.db.read { dbc in
        try Paper.fetchAll(dbc, sql: "SELECT * FROM papers")
    }
    for var paper in all {
        let cleanedTitle = MetadataSanitizer.clean(paper.title)
        let cleanedVenue = paper.venue.map(MetadataSanitizer.clean)
        let cleanedJournal = paper.journal.map(MetadataSanitizer.clean)
        let cleanedBooktitle = paper.booktitle.map(MetadataSanitizer.clean)
        let cleanedAbstract = paper.abstract.map(MetadataSanitizer.clean)
        guard cleanedTitle != paper.title || cleanedVenue != paper.venue
            || cleanedJournal != paper.journal || cleanedBooktitle != paper.booktitle
            || cleanedAbstract != paper.abstract
        else { continue }
        let before = paper.title
        paper.title = cleanedTitle
        paper.venue = cleanedVenue
        paper.journal = cleanedJournal
        paper.booktitle = cleanedBooktitle
        paper.abstract = cleanedAbstract
        if paper.isStub {
            try store.db.write { try paper.save($0) }
        } else {
            // 非stubはmeta.json（正本）も更新
            let authors = try store.authors(of: paper.id).map {
                PaperMeta.AuthorEntry(displayName: $0.displayName, s2AuthorId: $0.s2AuthorId, orcid: $0.orcid)
            }
            try store.savePaper(paper, authors: authors)
        }
        fixed += 1
        if before != cleanedTitle {
            print("  fixed: \(before.prefix(60))")
            print("    → \(cleanedTitle.prefix(60))")
        }
    }
    print("fix-titles: fixed \(fixed) paper(s)")

case "flag":
    // お気に入り/自著フラグのトグル（→ docs/09 2.2節）
    guard arguments.count >= 3, ["favorite", "own"].contains(arguments[2]) else {
        fail("flag <paper-id (prefix match allowed)> <favorite|own>")
    }
    let prefix = arguments[1]
    guard let paper = try store.allPapers().first(where: { $0.id.hasPrefix(prefix) }) else {
        fail("no paper matches paper-id \(prefix)")
    }
    if arguments[2] == "favorite" {
        try store.setFavorite(paper.id, !paper.isFavorite)
        print("favorite: \(!paper.isFavorite)  \(paper.title.prefix(50))")
    } else {
        try store.setOwn(paper.id, !paper.isOwn)
        print("own: \(!paper.isOwn)  \(paper.title.prefix(50))")
    }

case "delete":
    // 論文の削除（ディレクトリごとゴミ箱へ → docs/03 6節）
    guard arguments.count >= 2 else { fail("delete <paper-id (prefix match allowed)>") }
    let prefix = arguments[1]
    let matches = try store.allPapers().filter { $0.id.hasPrefix(prefix) }
    guard matches.count == 1, let paper = matches.first else {
        fail("\(matches.isEmpty ? "no papers match" : "multiple papers match") paper-id \(prefix)")
    }
    try store.deletePaper(id: paper.id)
    print("deleted: \(paper.id.prefix(8)) \(paper.title.prefix(60)) (folder moved to Trash)")

case "reconvert":
    // 高精度再変換（force_ocr + formula_enrichment → docs/05 5.1節）
    guard arguments.count >= 2 else { fail("reconvert <paper-id (prefix match allowed)>") }
    let prefix = arguments[1]
    guard let paper = try store.allPapers().first(where: { $0.id.hasPrefix(prefix) }) else {
        fail("no paper matches paper-id \(prefix)")
    }
    let job = try queue.enqueue(kind: .reconvert, paperId: paper.id, payload: [:], origin: .app)
    print("queued: \(job.id) (high-accuracy reconversion of \(paper.title.prefix(50)))")

case "retry-failed":
    let failed = try queue.jobs(status: .failed)
    for job in failed {
        try queue.retry(job.id)
        print("requeued: \(job.id.prefix(8)) \(job.kind)")
    }
    if failed.isEmpty { print("no failed jobs") }

case "process":
    let runner = makeRunner()
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        var total = 0
        while true {
            let n = await runner.tick()
            total += n
            if n == 0 { break }
            print("processed \(n) job(s)…")
        }
        print("done: \(total) job(s) processed")
        for job in (try? queue.jobs()) ?? [] {
            print("  \(job.id.prefix(8)) \(job.kind)\t\(job.status)\tstage=\(job.stage ?? "-")\(job.lastError.map { " error=\($0.prefix(100))" } ?? "")")
        }
        semaphore.signal()
    }
    semaphore.wait()

case "search":
    guard arguments.count >= 2 else { fail("search <query>") }
    let query = arguments[1...].joined(separator: " ")
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let embedder: QueryEmbedder? = WorkerLock.reusableClient()
        print(embedder != nil ? "[hybrid: FTS5 + semantic]" : "[keyword only: worker not running]")
        do {
            let search = HybridSearch(db: store.db)
            let (results, _) = try await search.search(query: query, topK: 10, embedder: embedder)
            for r in results {
                var strength = ""
                if let s = r.semanticScore { strength += " sem\(Int(s * 100))%" }
                if let k = r.keywordRank { strength += " kw#\(k)" }
                print("\(String(format: "%.4f", r.score))  [\(r.matchType.rawValue)\(strength)]\t\(r.title.prefix(50))\t§ \(r.sectionPath ?? "-")")
                print("        \(r.chunkText.replacingOccurrences(of: "\n", with: " ").prefix(120))")
            }
            if results.isEmpty { print("no results") }
        } catch {
            print("error: \(error)")
        }
        semaphore.signal()
    }
    semaphore.wait()

default:
    fail("unknown command: \(command)")
}
