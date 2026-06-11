import Foundation
import CryptoKit
import GRDB

/// 取り込みパイプラインの各ステージ実行を抽象化する（→ docs/04）。
/// 本物はMetadataResolver / URLSession / WorkerClientを束ね、テストはフェイクを注入する。
public protocol IngestStageExecutors: Sendable {
    /// resolve: 入力から書誌メタデータを確定
    func resolve(_ identifier: PaperIdentifier) async throws -> ResolvedMetadata
    /// fetch: PDFをダウンロードしてdestinationへ保存。取得不能（部分的成功）ならfalse
    func fetchPDF(meta: ResolvedMetadata, destination: URL) async throws -> Bool
    /// convert: Doclingでpaper.md / paper.docling.jsonをpaperDirへ書き出す。
    /// optionsで高精度再変換（force_ocr / formula_enrichment → docs/05 5.1節）を指定できる
    func convert(pdfPath: URL, outputDir: URL, options: WorkerClient.ConvertOptions) async throws
    /// embed: チャンクテキストのembedding生成（passage）
    func embed(texts: [String]) async throws -> [[Float]]
    /// ローカルPDF解決用: タイトル+著者でのbibliographic検索（→ docs/04 4節）。一致なしはnil
    func resolveBibliographic(title: String, author: String?) async throws -> ResolvedMetadata?
    /// 直接PDF URLのダウンロード（→ docs/04 2節）
    func downloadFile(from url: URL, to destination: URL) async throws
}

extension IngestStageExecutors {
    public func resolveBibliographic(title: String, author: String?) async throws -> ResolvedMetadata? {
        nil
    }

    public func downloadFile(from url: URL, to destination: URL) async throws {
        throw IngestError.permanent("このビルドは直接PDFダウンロードに未対応です")
    }

    /// 既定オプションでのconvert
    public func convert(pdfPath: URL, outputDir: URL) async throws {
        try await convert(pdfPath: pdfPath, outputDir: outputDir, options: WorkerClient.ConvertOptions())
    }
}

public enum IngestError: Error, Equatable, CustomStringConvertible {
    /// 重複検出（→ docs/04 5節）。既存paper_idを保持
    case duplicate(existingPaperId: String)
    /// 恒久的エラー（PDF破損等）。リトライしない
    case permanent(String)
    case invalidInput(String)

    public var description: String {
        switch self {
        case .duplicate(let id): return "重複: 既存論文 \(id)"
        case .permanent(let message): return message
        case .invalidInput(let message): return "不正な入力: \(message)"
        }
    }
}

/// ジョブ1件をステージ型ステートマシンとして実行する（→ docs/04 1節）。
/// 各ステージの成果物はファイルまたはDB行として永続化され、失敗ステージから再開できる。
public struct IngestPipeline: Sendable {
    public let store: LibraryStore
    public let queue: JobQueue
    public let executors: IngestStageExecutors
    public let chunker: Chunker

    public init(store: LibraryStore, queue: JobQueue, executors: IngestStageExecutors, chunker: Chunker = Chunker()) {
        self.store = store
        self.queue = queue
        self.executors = executors
        self.chunker = chunker
    }

    /// ジョブを実行する（claim済み前提）。
    /// 戻り値は最終的なpapers.status（部分的成功を含む）。
    @discardableResult
    public func run(job: Job) async throws -> PaperStatus {
        let payload = queue.payload(of: job)
        var paperId = job.paperId
        // 失敗ステージから再開（完了済みステージの次から → docs/04 7節）
        let completedStage = job.jobStage
        var stage: JobStage = completedStage.flatMap(\.next) ?? .resolve
        if completedStage == nil { stage = .resolve }

        do {
            // resolve
            if stage == .resolve {
                paperId = try await runResolve(job: job, payload: payload)
                try queue.updateStage(job.id, stage: .resolve)
                stage = .fetch
            }
            guard let paperId else { throw IngestError.invalidInput("paper_idが未確定です") }

            // fetch
            if stage == .fetch {
                try await runFetch(job: job, paperId: paperId)
                try queue.updateStage(job.id, stage: .fetch)
                stage = .convert
            }

            // PDFがない場合はここで完了（metadata_onlyの部分的成功 → docs/04 6節）
            let pdfPath = store.layout.pdfPath(paperId)
            if !FileManager.default.fileExists(atPath: pdfPath.path) {
                try updateStatus(paperId, .metadataOnly)
                try queue.succeed(job.id)
                return .metadataOnly
            }

            // resolve優先スケジューリング（→ docs/04 8節）:
            // 新規ジョブは書誌確定（resolve+fetch）までで一旦キューへ戻し、
            // 一括取り込み時に全件の書誌登録を重い変換より先に終わらせる。
            // 再開ジョブ（completedStage != nil）は中断なく最後まで実行する
            if completedStage == nil {
                try queue.requeueForContinuation(job.id)
                return try store.paper(id: paperId)?.paperStatus ?? .metadataOnly
            }

            // convert（成果物が既にあればスキップ: 再開・ローカルPDF先行変換の冪等性）
            if stage == .convert {
                let fm = FileManager.default
                let alreadyConverted = fm.fileExists(atPath: store.layout.markdownPath(paperId).path)
                    && fm.fileExists(atPath: store.layout.doclingJSONPath(paperId).path)
                if !alreadyConverted {
                    try updateStatusPreservingPDFOnly(paperId, .converting)
                    try await executors.convert(pdfPath: pdfPath, outputDir: store.layout.paperDir(paperId))
                }
                try queue.updateStage(job.id, stage: .convert)
                stage = .chunk
            }

            // chunk
            var chunkIds: [Int64] = []
            var pieces: [Chunker.Piece] = []
            let index = SearchIndex(db: store.db)
            if stage == .chunk || stage == .embed || stage == .index {
                pieces = try buildPieces(paperId: paperId)
                // chunk成果物はDB行。embed再開時も同じpiecesから再投入する（冪等）
                chunkIds = try index.indexPaper(paperId: paperId, pieces: pieces)
                try updateConversionWarnings(paperId)
                if stage == .chunk {
                    try queue.updateStage(job.id, stage: .chunk)
                    stage = .embed
                }
            }

            // embed
            if stage == .embed {
                let embeddings = try await executors.embed(texts: pieces.map(\.text))
                try index.attachEmbeddings(chunkIds: chunkIds, embeddings: embeddings)
                try queue.updateStage(job.id, stage: .embed)
                stage = .index
            }

            // index（FTS5はchunk段階で投入済み。整合性確認 → docs/04 1節）
            if stage == .index {
                try verifyIndex(paperId: paperId, expectedChunks: pieces.count)
                try queue.updateStage(job.id, stage: .index)
            }

            // 書誌未解決のローカルPDFはpdf_onlyのまま完了（手動解決UIの対象 → docs/04 4節）
            let unresolved = try store.paper(id: paperId)?.paperStatus == .pdfOnly
            if !unresolved {
                try updateStatus(paperId, .indexed)
            }
            try queue.succeed(job.id)
            return unresolved ? .pdfOnly : .indexed

        } catch let error as IngestError {
            switch error {
            case .duplicate(let existingId):
                // 重複はジョブをcancelledにし、既存エントリを返す（→ docs/04 5節）
                try queue.cancel(job.id, reason: "duplicate:\(existingId)")
                throw error
            case .permanent, .invalidInput:
                try queue.fail(job.id, error: error.description, permanent: true)
                if let paperId { try? updateStatus(paperId, .failed) }
                throw error
            }
        } catch {
            // 一時的エラー: バックオフリトライ（→ docs/04 7節）
            let status = try queue.fail(job.id, error: String(describing: error))
            if status == .failed, let paperId { try? updateStatus(paperId, .failed) }
            throw error
        }
    }

    // MARK: - ステージ実装

    func runResolve(job: Job, payload: [String: String]) async throws -> String {
        let parsed = payload["input"].flatMap(PaperIdentifier.parse) ?? parseRaw(payload)
        guard let identifier = parsed else {
            throw IngestError.invalidInput("解決できない入力: \(payload)")
        }
        // ローカルPDFは別経路: convert先行 → bibliographic検索（→ docs/04 4節）
        if case .localPDF(let path) = identifier {
            return try await runResolveLocalPDF(job: job, sourcePath: path)
        }
        // 直接PDF URL: ダウンロードしてローカルPDF解決に帰着（→ docs/04 2節）
        if case .directPDFURL(let urlString) = identifier {
            guard let url = URL(string: urlString) else {
                throw IngestError.invalidInput("不正なPDF URL: \(urlString)")
            }
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("paperd-download-\(UUID().uuidString).pdf")
            try await executors.downloadFile(from: url, to: temp)
            defer { try? FileManager.default.removeItem(at: temp) }
            return try await runResolveLocalPDF(job: job, sourcePath: temp.path)
        }
        let meta: ResolvedMetadata
        do {
            meta = try await executors.resolve(identifier)
        } catch let error as MetadataError {
            switch error {
            case .notFound, .parse:
                // 不正なID・書誌を特定できないページはリトライしても解決しない（→ docs/04 2節）
                throw IngestError.permanent(error.description)
            default:
                throw error  // ネットワーク系はバックオフリトライ
            }
        }

        // 重複検出: doi / arxiv_id 一致（→ docs/04 5節）
        let existing = try store.db.read { dbc -> Paper? in
            if let doi = meta.doi, let p = try Paper.filter(Column("doi") == doi).fetchOne(dbc) { return p }
            if let arxivId = meta.arxivId, let p = try Paper.filter(Column("arxiv_id") == arxivId).fetchOne(dbc) { return p }
            return nil
        }
        if let existing, existing.id != job.paperId {
            // stub論文の扱い
            if existing.isStub {
                if let currentId = job.paperId, try store.paper(id: currentId) != nil {
                    // 手動解決等で既にpaper行（PDF・ファイル持ち）がある場合: stubを吸収してそのまま続行
                    //（→ docs/04 4節, docs/08 4節）
                    try CitationStore(db: store.db).absorb(stubId: existing.id, into: currentId)
                } else {
                    // 通常の取り込み: stub行を同一行のまま昇格させる（→ docs/08 4節）
                    var paper = existing
                    meta.apply(to: &paper)
                    paper.isStub = false
                    paper.paperStatus = .metadataOnly
                    try savePaperResolvingConflicts(paper, authors: meta.authors.map { .init(displayName: $0.displayName, s2AuthorId: $0.s2AuthorId, orcid: $0.orcid) }, cleanupDirOnConflict: true)
                    try queue.setPaperId(job.id, paperId: paper.id)
                    return paper.id
                }
            } else {
                throw IngestError.duplicate(existingPaperId: existing.id)
            }
        }

        // 既存ジョブが既にpaper行を作っている場合（再開）はそれを更新
        if let paperId = job.paperId, var paper = try store.paper(id: paperId) {
            meta.apply(to: &paper)
            paper.paperStatus = .metadataOnly
            try savePaperResolvingConflicts(paper, authors: meta.authors.map { .init(displayName: $0.displayName, s2AuthorId: $0.s2AuthorId, orcid: $0.orcid) })
            return paperId
        }

        var paper = Paper(title: meta.title, status: .metadataOnly)
        meta.apply(to: &paper)
        try savePaperResolvingConflicts(paper, authors: meta.authors.map { .init(displayName: $0.displayName, s2AuthorId: $0.s2AuthorId, orcid: $0.orcid) }, cleanupDirOnConflict: true)
        try queue.setPaperId(job.id, paperId: paper.id)
        // fetchステージへのヒント（pdfURL）はpayloadでなくResolvedMetadata再取得で賄う簡易実装のため、ここで保存
        if let pdfURL = meta.pdfURL {
            try store.db.write { dbc in
                try dbc.execute(sql: "UPDATE jobs SET payload = json_set(payload, '$.pdf_url', ?) WHERE id = ?", arguments: [pdfURL, job.id])
            }
        }
        return paper.id
    }

    /// ローカルPDFの解決（→ docs/04 4節）:
    /// 1. PDFをライブラリへコピーし、pdf_hashで即時重複検出
    /// 2. convertを先行実行してDocling抽出のタイトルを得る
    /// 3. タイトルでCrossref bibliographic検索 → 一致すればDOI解決
    /// 4. 失敗時は status = pdf_only として登録（本文検索は機能、bibtexは不完全）
    func runResolveLocalPDF(job: Job, sourcePath: String) async throws -> String {
        let source = URL(fileURLWithPath: sourcePath)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw IngestError.invalidInput("PDFが見つかりません: \(sourcePath)")
        }

        // pdf_hash重複検出（PDFドロップ直後 → docs/04 5節）
        let hash = try Self.sha256(of: source)
        let duplicate = try store.db.read { dbc in
            try Paper.filter(Column("pdf_hash") == "sha256:\(hash)").fetchOne(dbc)
        }
        if let duplicate, duplicate.id != job.paperId {
            throw IngestError.duplicate(existingPaperId: duplicate.id)
        }

        // ① テキスト層からの先行解決（Doclingなし・ミリ秒 → docs/04 4節）。
        // 多くの出版社PDFは1ページ目にDOI/arXiv IDを印字している。
        // 抽出できれば変換を待たずに書誌登録・重複検出が完了する。
        // （paperId付きジョブ = 既存行の再解決は従来フローを使う）
        if job.paperId == nil, let head = PDFTextExtractor.headText(of: source) {
            // References以降の引用DOIを自分のIDと誤認しない（→ docs/04 4節）
            let idSource = Self.truncateAtReferences(head)
            var identifier: PaperIdentifier?
            if let doi = PaperIdentifier.extractDOI(from: idSource) {
                identifier = .doi(doi)
            } else if let arxiv = PaperIdentifier.extractArxivID(from: idSource) {
                identifier = .arxiv(id: arxiv.id, version: arxiv.version)
            }
            if let identifier, let meta = try? await executors.resolve(identifier) {
                return try registerPreResolved(meta: meta, source: source, hash: hash, job: job)
            }
        }

        // paper行作成（タイトルは仮にファイル名）+ PDF配置
        var paper: Paper
        if let existingId = job.paperId, let existing = try store.paper(id: existingId) {
            paper = existing  // 再開
        } else {
            paper = Paper(
                title: source.deletingPathExtension().lastPathComponent,
                status: .pdfOnly
            )
            paper.pdfHash = "sha256:\(hash)"
        }
        let dir = store.layout.paperDir(paper.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = store.layout.pdfPath(paper.id)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: source, to: destination)
        }
        try store.savePaper(paper, authors: [])
        try queue.setPaperId(job.id, paperId: paper.id)

        // convert先行（再解決時は既存成果物を再利用）
        let fm = FileManager.default
        let alreadyConverted = fm.fileExists(atPath: store.layout.markdownPath(paper.id).path)
            && fm.fileExists(atPath: store.layout.doclingJSONPath(paper.id).path)
        if !alreadyConverted {
            try await executors.convert(pdfPath: destination, outputDir: dir)
        }

        // 本文冒頭テキストとタイトル候補
        let markdownHead = Self.documentHead(markdownPath: store.layout.markdownPath(paper.id))
        var extractedTitle: String?
        if let data = fm.contents(atPath: store.layout.doclingJSONPath(paper.id).path),
           let items = try? DoclingParser.parse(data: data) {
            extractedTitle = DoclingParser.titleCandidate(items: items)
        }

        // ① 本文冒頭からのID抽出（最優先 → docs/04 4節）。
        //    多くの論文は1ページ目に自身のDOI/arXiv IDを印字しており、タイトル検索より確実
        var meta: ResolvedMetadata?
        // ID抽出はReferences見出しより前に限定（タイトル照合はmarkdownHead全体を使う → docs/04 4節）
        let idSource = Self.truncateAtReferences(markdownHead)
        if let doi = PaperIdentifier.extractDOI(from: idSource) {
            meta = try? await executors.resolve(.doi(doi))
        }
        if meta == nil, let arxiv = PaperIdentifier.extractArxivID(from: idSource) {
            meta = try? await executors.resolve(.arxiv(id: arxiv.id, version: arxiv.version))
        }

        // ② タイトルでのbibliographic検索 + 解決結果の検証（→ docs/04 4節）
        if meta == nil, let candidate = extractedTitle, !candidate.isEmpty,
           let resolved = try? await executors.resolveBibliographic(title: candidate, author: nil),
           Self.resolvedTitleMatches(resolved.title, candidate: candidate, documentHead: markdownHead) {
            meta = resolved
        }

        if var meta = meta {
            // 解決後DOIの重複チェックと合流（→ docs/04 4節）
            let existing = try store.db.read { dbc -> Paper? in
                if let doi = meta.doi,
                   let p = try Paper.filter(Column("doi") == doi && Column("id") != paper.id).fetchOne(dbc) { return p }
                if let arxivId = meta.arxivId,
                   let p = try Paper.filter(Column("arxiv_id") == arxivId && Column("id") != paper.id).fetchOne(dbc) { return p }
                return nil
            }
            if let existing {
                if existing.isStub {
                    // 引用グラフ由来のstub行を吸収（エッジ付け替え + stub削除 → docs/08 4節）
                    try CitationStore(db: store.db).absorb(stubId: existing.id, into: paper.id)
                } else if !fm.fileExists(atPath: store.layout.pdfPath(existing.id).path) {
                    // PDF未取得のmetadata_only行へ合流（URL/ID登録 → 後からPDFドロップのユースケース）
                    let mergedId = try mergeTempPaper(tempId: paper.id, into: existing.id, job: job)
                    var merged = try store.paper(id: mergedId)!
                    meta.apply(to: &merged)
                    merged.paperStatus = .metadataOnly
                    try savePaperResolvingConflicts(merged, authors: meta.authors.map {
                        .init(displayName: $0.displayName, s2AuthorId: $0.s2AuthorId, orcid: $0.orcid)
                    })
                    return mergedId
                } else {
                    // 真の重複: 作りかけの行とディレクトリを破棄してcancel（→ docs/04 5節）。
                    // jobs.paper_idのFK制約があるため、先にジョブを既存行へ付け替える
                    try queue.setPaperId(job.id, paperId: existing.id)
                    _ = try store.db.write { try Paper.deleteOne($0, key: paper.id) }
                    try? FileManager.default.removeItem(at: dir)
                    throw IngestError.duplicate(existingPaperId: existing.id)
                }
            }
            meta.apply(to: &paper)
            paper.paperStatus = .metadataOnly
            try savePaperResolvingConflicts(paper, authors: meta.authors.map {
                .init(displayName: $0.displayName, s2AuthorId: $0.s2AuthorId, orcid: $0.orcid)
            }, cleanupDirOnConflict: true)
            return paper.id
        }

        // ③ 未解決時のフォールバック: 既存のPDF未取得論文のタイトルが本文冒頭に含まれていれば合流
        //    （ネットワーク不要 → docs/04 4節）
        if let match = try findPDFLessPaperByTitle(in: markdownHead, excluding: paper.id) {
            return try mergeTempPaper(tempId: paper.id, into: match.id, job: job)
        }

        // 解決失敗: タイトルだけは抽出結果で更新し、pdf_onlyのまま
        if let title = extractedTitle, !title.isEmpty {
            paper.title = title
        }
        paper.paperStatus = .pdfOnly
        try store.savePaper(paper, authors: [])
        return paper.id
    }

    /// resolve系のsavePaper: 並行ジョブとのUNIQUE競合（同一DOI/arXiv IDへの同時INSERT）を
    /// 正規の重複検出（duplicate → cancel）に変換する（→ docs/04 5節）。
    /// - Parameter cleanupDirOnConflict: 競合時に作りかけのディレクトリを破棄する（新規行の登録時のみtrue）
    public func savePaperResolvingConflicts(
        _ paper: Paper,
        authors: [PaperMeta.AuthorEntry],
        cleanupDirOnConflict: Bool = false
    ) throws {
        do {
            try store.savePaper(paper, authors: authors)
        } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
            if cleanupDirOnConflict {
                try? FileManager.default.removeItem(at: store.layout.paperDir(paper.id))
            }
            let existing = try store.db.read { dbc -> Paper? in
                if let doi = paper.doi,
                   let p = try Paper.filter(Column("doi") == doi && Column("id") != paper.id).fetchOne(dbc) { return p }
                if let arxivId = paper.arxivId,
                   let p = try Paper.filter(Column("arxiv_id") == arxivId && Column("id") != paper.id).fetchOne(dbc) { return p }
                return nil
            }
            if let existing {
                throw IngestError.duplicate(existingPaperId: existing.id)
            }
            throw IngestError.permanent("DB制約エラー: \(error.message ?? String(describing: error))")
        }
    }

    /// 先行解決の結果を登録する（→ docs/04 4節）。
    /// 重複（PDF取得済みの既存行）は**変換コストゼロで**cancel、metadata_only行へは合流、stubは吸収。
    func registerPreResolved(meta: ResolvedMetadata, source: URL, hash: String, job: Job) throws -> String {
        let fm = FileManager.default
        let existing = try store.db.read { dbc -> Paper? in
            if let doi = meta.doi, let p = try Paper.filter(Column("doi") == doi).fetchOne(dbc) { return p }
            if let arxivId = meta.arxivId, let p = try Paper.filter(Column("arxiv_id") == arxivId).fetchOne(dbc) { return p }
            return nil
        }

        if let existing, existing.isStub {
            // stub昇格: 同一行のまま取り込み行へ（→ docs/08 4節）。
            // 「新規行をINSERT → 後からstub吸収」の順序はstubが保有するDOIとUNIQUE競合して
            // 必ず失敗するため、runResolveと同じく行を昇格させる（引用エッジも温存される）
            try fm.createDirectory(at: store.layout.paperDir(existing.id), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: store.layout.pdfPath(existing.id))
            var paper = existing
            meta.apply(to: &paper)
            paper.pdfHash = "sha256:\(hash)"
            paper.isStub = false
            paper.paperStatus = .metadataOnly
            try savePaperResolvingConflicts(paper, authors: meta.authors.map {
                .init(displayName: $0.displayName, s2AuthorId: $0.s2AuthorId, orcid: $0.orcid)
            })
            try queue.setPaperId(job.id, paperId: existing.id)
            return existing.id
        }

        if let existing, !existing.isStub {
            if fm.fileExists(atPath: store.layout.pdfPath(existing.id).path) {
                // 重複: 変換前にスキップ（→ docs/04 4節）
                try queue.setPaperId(job.id, paperId: existing.id)
                throw IngestError.duplicate(existingPaperId: existing.id)
            }
            // PDF未取得のmetadata_only行へ合流
            try fm.createDirectory(at: store.layout.paperDir(existing.id), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: store.layout.pdfPath(existing.id))
            var paper = existing
            meta.apply(to: &paper)
            paper.pdfHash = "sha256:\(hash)"
            paper.paperStatus = .metadataOnly
            try savePaperResolvingConflicts(paper, authors: meta.authors.map {
                .init(displayName: $0.displayName, s2AuthorId: $0.s2AuthorId, orcid: $0.orcid)
            })
            try queue.setPaperId(job.id, paperId: existing.id)
            return existing.id
        }

        // 新規行を作成してPDFを配置
        var paper = Paper(title: meta.title, status: .metadataOnly)
        meta.apply(to: &paper)
        paper.pdfHash = "sha256:\(hash)"
        try fm.createDirectory(at: store.layout.paperDir(paper.id), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: store.layout.pdfPath(paper.id))
        try savePaperResolvingConflicts(paper, authors: meta.authors.map {
            .init(displayName: $0.displayName, s2AuthorId: $0.s2AuthorId, orcid: $0.orcid)
        }, cleanupDirOnConflict: true)
        try queue.setPaperId(job.id, paperId: paper.id)
        return paper.id
    }

    /// References見出し以降を取り除く（→ docs/04 4節）。
    /// 短い文書（Supplementary等）では参考文献がID抽出窓に入り、
    /// 引用先のDOIを自分のIDと誤認する交絡が起きるため、ID抽出はこの結果に対して行う
    public static func truncateAtReferences(_ text: String) -> String {
        let markers: Set<String> = ["references", "bibliography", "literature cited", "参考文献", "引用文献"]
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let stripped = line
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#*=:． 　"))
                .lowercased()
            if markers.contains(stripped) {
                return lines[..<i].joined(separator: "\n")
            }
        }
        return text
    }

    /// 本文冒頭（ID抽出・タイトル照合用）
    static func documentHead(markdownPath: URL, limit: Int = 6000) -> String {
        guard let data = FileManager.default.contents(atPath: markdownPath.path),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return String(text.prefix(limit))
    }

    /// bibliographic解決結果の検証: 解決タイトルが抽出候補と十分一致するか、本文冒頭に含まれること
    static func resolvedTitleMatches(_ resolvedTitle: String, candidate: String, documentHead: String) -> Bool {
        if TextMatch.tokenOverlap(resolvedTitle, candidate) >= 0.5 { return true }
        return TextMatch.containsNormalized(documentHead, resolvedTitle)
    }

    /// 本文冒頭にタイトルが含まれるPDF未取得論文を探す（一意の場合のみ返す）
    func findPDFLessPaperByTitle(in documentHead: String, excluding paperId: String) throws -> Paper? {
        let candidates = try store.db.read { dbc in
            try Paper
                .filter(Column("is_stub") == false && Column("id") != paperId
                        && Column("status") == PaperStatus.metadataOnly.rawValue)
                .fetchAll(dbc)
        }
        let matches = candidates.filter { candidate in
            guard candidate.title.count >= 15 else { return false }
            guard !FileManager.default.fileExists(atPath: store.layout.pdfPath(candidate.id).path) else { return false }
            return TextMatch.containsNormalized(documentHead, candidate.title)
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// 作りかけの行（temp）のファイルを既存行へ移して合流する（→ docs/04 4節）。
    /// 既存行のIDが正（メタデータ・引用エッジ持ち）。tempの行とディレクトリは破棄する。
    func mergeTempPaper(tempId: String, into existingId: String, job: Job) throws -> String {
        let fm = FileManager.default
        let tempDir = store.layout.paperDir(tempId)
        let destDir = store.layout.paperDir(existingId)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        for file in ["paper.pdf", "paper.md", "paper.docling.json"] {
            let src = tempDir.appendingPathComponent(file)
            let dst = destDir.appendingPathComponent(file)
            guard fm.fileExists(atPath: src.path) else { continue }
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.moveItem(at: src, to: dst)
        }
        try queue.setPaperId(job.id, paperId: existingId)
        try store.db.write { dbc in
            try dbc.execute(sql: "DELETE FROM jobs WHERE paper_id = ? AND id != ?", arguments: [tempId, job.id])
            try Paper.deleteOne(dbc, key: tempId)
        }
        try? fm.removeItem(at: tempDir)

        // 合流先のpdf_hashを更新
        if var existing = try store.paper(id: existingId) {
            let hash = try Self.sha256(of: store.layout.pdfPath(existingId))
            existing.pdfHash = "sha256:\(hash)"
            let authors = try store.authors(of: existingId).map {
                PaperMeta.AuthorEntry(displayName: $0.displayName, s2AuthorId: $0.s2AuthorId, orcid: $0.orcid)
            }
            try store.savePaper(existing, authors: authors)
        }
        return existingId
    }

    func parseRaw(_ payload: [String: String]) -> PaperIdentifier? {
        if let arxiv = payload["arxiv_id"], let parsed = PaperIdentifier.parseArxivID(arxiv) {
            return .arxiv(id: parsed.id, version: parsed.version)
        }
        if let doi = payload["doi"], let parsed = PaperIdentifier.parseDOI(doi) {
            return .doi(parsed)
        }
        if let url = payload["url"] {
            return PaperIdentifier.parseURL(url)
        }
        if let pdf = payload["pdf_path"] {
            return .localPDF(path: pdf)
        }
        return nil
    }

    func runFetch(job: Job, paperId: String) async throws {
        guard var paper = try store.paper(id: paperId) else { throw IngestError.invalidInput("論文が存在しません: \(paperId)") }
        let destination = store.layout.pdfPath(paperId)
        if FileManager.default.fileExists(atPath: destination.path) {
            // 既に取得済み（再開 / ユーザ提供）。ハッシュのみ更新
        } else {
            // payloadはDBから読み直す: resolveステージが同一run内でpdf_urlを追記している
            //（runの冒頭でクレームしたJobスナップショットには反映されていない → docs/04 2節）
            let currentJob = (try? queue.job(id: job.id)) ?? job
            let payload = queue.payload(of: currentJob ?? job)
            var meta = ResolvedMetadata(title: paper.title, arxivId: paper.arxivId, url: paper.url)
            meta.doi = paper.doi
            meta.pdfURL = payload["pdf_url"]
            let fetched = try await executors.fetchPDF(meta: meta, destination: destination)
            guard fetched else { return }  // 全ソース失敗 → metadata_onlyで完了（呼び出し側で処理）
        }

        // pdf_hash計算 + 重複検出（→ docs/04 5節）
        let hash = try Self.sha256(of: destination)
        let duplicate = try store.db.read { dbc in
            try Paper.filter(Column("pdf_hash") == "sha256:\(hash)" && Column("id") != paperId).fetchOne(dbc)
        }
        if let duplicate {
            throw IngestError.duplicate(existingPaperId: duplicate.id)
        }
        paper.pdfHash = "sha256:\(hash)"
        let authors = try store.authors(of: paperId).map {
            PaperMeta.AuthorEntry(displayName: $0.displayName, s2AuthorId: $0.s2AuthorId, orcid: $0.orcid)
        }
        try store.savePaper(paper, authors: authors)
    }

    /// 書誌チャンク（タイトル+アブストラクト）+ 本文チャンク + ノートチャンク（→ docs/06 2節）。
    /// 本文は paper.corrected.md があればそちらを優先（修正がRAGにも反映される → docs/05 5.2節）
    func buildPieces(paperId: String) throws -> [Chunker.Piece] {
        guard let paper = try store.paper(id: paperId) else { throw IngestError.invalidInput("論文が存在しません: \(paperId)") }
        var pieces: [Chunker.Piece] = []
        if paper.paperStatus != .pdfOnly {
            pieces.append(chunker.titleAbstractPiece(title: paper.title, abstract: paper.abstract))
        }
        let corrector = FulltextCorrector(layout: store.layout)
        if corrector.hasCorrections(paperId: paperId),
           let corrected = corrector.effectiveMarkdown(paperId: paperId) {
            let items = MarkdownChunkSource.items(fromMarkdown: corrected)
            pieces.append(contentsOf: chunker.chunk(items: items))
        } else if let data = FileManager.default.contents(atPath: store.layout.doclingJSONPath(paperId).path) {
            let items = try DoclingParser.parse(data: data)
            pieces.append(contentsOf: chunker.chunk(items: items))
        }
        if let note = store.note(of: paperId) {
            pieces.append(contentsOf: chunker.chunkNote(note))
        }
        return pieces
    }

    /// 変換品質検知（→ docs/05 4.1節）。有効Markdown（修正があれば修正版）を走査してキャッシュする
    func updateConversionWarnings(_ paperId: String) throws {
        let corrector = FulltextCorrector(layout: store.layout)
        guard let markdown = corrector.effectiveMarkdown(paperId: paperId) else { return }
        let count = ConversionQualityChecker().totalWarningCount(markdown)
        try store.db.write { dbc in
            try dbc.execute(
                sql: "UPDATE papers SET conversion_warnings = ? WHERE id = ?",
                arguments: [count, paperId])
        }
    }

    // MARK: - reindex / reconvert（→ docs/05 5節）

    /// チャンク・embedding・FTSの再構築（修正Markdown反映・モデル変更時）
    @discardableResult
    public func runReindex(job: Job) async throws -> PaperStatus {
        guard let paperId = job.paperId else {
            try queue.fail(job.id, error: "reindexにはpaper_idが必要です", permanent: true)
            throw IngestError.invalidInput("reindexにはpaper_idが必要です")
        }
        do {
            let pieces = try buildPieces(paperId: paperId)
            let index = SearchIndex(db: store.db)
            let chunkIds = try index.indexPaper(paperId: paperId, pieces: pieces)
            let embeddings = try await executors.embed(texts: pieces.map(\.text))
            try index.attachEmbeddings(chunkIds: chunkIds, embeddings: embeddings)
            try verifyIndex(paperId: paperId, expectedChunks: pieces.count)
            try updateConversionWarnings(paperId)
            try queue.succeed(job.id)
            return try store.paper(id: paperId)?.paperStatus ?? .indexed
        } catch {
            try handleMaintenanceError(error, job: job)
            throw error
        }
    }

    /// 高精度再変換（force_ocr + formula_enrichment → docs/05 5.1節）。
    /// convert以降を再実行してpaper.md / paper.docling.jsonを上書きする
    @discardableResult
    public func runReconvert(job: Job) async throws -> PaperStatus {
        guard let paperId = job.paperId else {
            try queue.fail(job.id, error: "reconvertにはpaper_idが必要です", permanent: true)
            throw IngestError.invalidInput("reconvertにはpaper_idが必要です")
        }
        let pdfPath = store.layout.pdfPath(paperId)
        guard FileManager.default.fileExists(atPath: pdfPath.path) else {
            try queue.fail(job.id, error: "paper.pdfがありません（PDF未取得の論文は再変換できません）", permanent: true)
            throw IngestError.invalidInput("paper.pdfがありません: \(paperId)")
        }
        do {
            let original = try store.paper(id: paperId)?.paperStatus
            // ステージ再開: convert完了済みのリトライでは高コストな再変換をスキップする
            // （embed等の後段の一時失敗のたびにOCR込みの変換をやり直さない → docs/04 7節の原則）
            if job.jobStage == nil {
                try updateStatusPreservingPDFOnly(paperId, .converting)
                try await executors.convert(
                    pdfPath: pdfPath,
                    outputDir: store.layout.paperDir(paperId),
                    options: .highQuality)
                try queue.updateStage(job.id, stage: .convert)

                // 既存の修正は基底テキストが変わるため破棄（履歴に記録 → docs/05 5.1節)。
                // 残すと古い修正版が新しい変換結果を隠し続ける
                let corrector = FulltextCorrector(layout: store.layout)
                if corrector.hasCorrections(paperId: paperId) {
                    try corrector.revert(
                        paperId: paperId,
                        note: "superseded by reconvert（高精度再変換により基底テキストが更新されたため修正を破棄）")
                }
            }

            let pieces = try buildPieces(paperId: paperId)
            let index = SearchIndex(db: store.db)
            let chunkIds = try index.indexPaper(paperId: paperId, pieces: pieces)
            try queue.updateStage(job.id, stage: .chunk)
            let embeddings = try await executors.embed(texts: pieces.map(\.text))
            try index.attachEmbeddings(chunkIds: chunkIds, embeddings: embeddings)
            try queue.updateStage(job.id, stage: .embed)
            try verifyIndex(paperId: paperId, expectedChunks: pieces.count)
            try queue.updateStage(job.id, stage: .index)
            try updateConversionWarnings(paperId)

            let final: PaperStatus = (original == .pdfOnly) ? .pdfOnly : .indexed
            try updateStatus(paperId, final)
            try queue.succeed(job.id)
            return final
        } catch {
            try handleMaintenanceError(error, job: job)
            throw error
        }
    }

    /// reindex/reconvertの失敗分類（runの分類と同じ規則）
    func handleMaintenanceError(_ error: Error, job: Job) throws {
        if let workerError = error as? WorkerClient.WorkerAPIError, workerError.isPermanent {
            try queue.fail(job.id, error: workerError.description, permanent: true)
        } else if let ingestError = error as? IngestError {
            try queue.fail(job.id, error: ingestError.description, permanent: true)
        } else {
            try queue.fail(job.id, error: String(describing: error))
        }
    }

    func verifyIndex(paperId: String, expectedChunks: Int) throws {
        let count = try store.db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM chunks WHERE paper_id = ?", arguments: [paperId]) ?? 0
        }
        guard count == expectedChunks else {
            throw IngestError.permanent("インデックス不整合: chunks=\(count), expected=\(expectedChunks)")
        }
    }

    func updateStatus(_ paperId: String, _ status: PaperStatus) throws {
        guard var paper = try store.paper(id: paperId) else { return }
        paper.paperStatus = status
        let authors = try store.authors(of: paperId).map {
            PaperMeta.AuthorEntry(displayName: $0.displayName, s2AuthorId: $0.s2AuthorId, orcid: $0.orcid)
        }
        try store.savePaper(paper, authors: authors)
    }

    /// pdf_only（書誌未解決）は維持する。完了時のindexed/pdf_only判定に使うため
    func updateStatusPreservingPDFOnly(_ paperId: String, _ status: PaperStatus) throws {
        guard let paper = try store.paper(id: paperId) else { return }
        if paper.paperStatus == .pdfOnly { return }
        try updateStatus(paperId, status)
    }

    public static func sha256(of file: URL) throws -> String {
        let data = try Data(contentsOf: file)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
