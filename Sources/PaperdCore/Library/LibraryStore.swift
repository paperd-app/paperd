import Foundation
import GRDB

public enum LibraryError: Error, Equatable, CustomStringConvertible {
    case notInitialized(String)
    case paperNotFound(String)
    case invalidLibrary(String)

    public var description: String {
        switch self {
        case .notInitialized(let path):
            return "Library is not initialized: \(path). Launch the paperd app once to initialize the library."
        case .paperNotFound(let id):
            return "Paper not found: \(id)"
        case .invalidLibrary(let reason):
            return "Invalid library: \(reason)"
        }
    }
}

/// ファイル正本（meta.json / collections.json）とDBインデックスの同期を担う。
/// 書き込み順序は「ファイル → DB」（クラッシュ時はファイルが新しく、再構築で回復 → docs/03 3節）。
public final class LibraryStore: Sendable {
    public let layout: LibraryLayout
    public let db: AppDatabase

    public init(layout: LibraryLayout, db: AppDatabase) {
        self.layout = layout
        self.db = db
    }

    // MARK: - 初期化 / オープン

    /// ライブラリを新規作成（既存なら何もしない）してDBを開く
    public static func create(at root: URL) throws -> LibraryStore {
        let layout = LibraryLayout(root: root)
        let fm = FileManager.default
        try fm.createDirectory(at: layout.papersDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: layout.indexDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: layout.libraryJSON.path) {
            let descriptor = LibraryDescriptor()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(descriptor).write(to: layout.libraryJSON, options: .atomic)
        }
        let db = try AppDatabase(path: layout.databasePath.path)
        return LibraryStore(layout: layout, db: db)
    }

    /// 既存ライブラリを開く。library.jsonがなければエラー
    public static func open(at root: URL) throws -> LibraryStore {
        let layout = LibraryLayout(root: root)
        guard FileManager.default.fileExists(atPath: layout.libraryJSON.path) else {
            throw LibraryError.notInitialized(root.path)
        }
        let db = try AppDatabase(path: layout.databasePath.path)
        return LibraryStore(layout: layout, db: db)
    }

    // MARK: - 論文の保存

    /// 論文（メタデータ + 著者 + コレクション所属）を保存する。
    /// meta.jsonを先に書き、同一トランザクションでDB行を更新する。
    public func savePaper(
        _ paper: Paper,
        authors: [PaperMeta.AuthorEntry],
        citationKeyOverride: String? = nil
    ) throws {
        var paper = paper
        paper.updatedAt = PaperdDates.nowString()

        // stub行はmeta.jsonを持たない（→ docs/02 1節）
        if !paper.isStub {
            let dir = layout.paperDir(paper.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let meta = PaperMeta(
                paper: paper,
                authors: authors.map { Author(displayName: $0.displayName, s2AuthorId: $0.s2AuthorId, orcid: $0.orcid) },
                citationKeyOverride: citationKeyOverride
            )
            try meta.encode().write(to: layout.metaJSONPath(paper.id), options: .atomic)
        }

        try db.write { dbc in
            try paper.save(dbc)
            try Self.replaceAuthors(dbc, paperId: paper.id, authors: authors)
        }
    }

    /// 著者行を差し替える。s2_author_idが一致する既存行のみ再利用（名寄せはv1では行わない → docs/02）
    static func replaceAuthors(_ db: Database, paperId: String, authors: [PaperMeta.AuthorEntry]) throws {
        try PaperAuthor.filter(Column("paper_id") == paperId).deleteAll(db)
        for (i, entry) in authors.enumerated() {
            let author: Author
            if let s2id = entry.s2AuthorId,
               let existing = try Author.filter(Column("s2_author_id") == s2id).fetchOne(db) {
                author = existing
            } else {
                let newAuthor = Author(displayName: entry.displayName, s2AuthorId: entry.s2AuthorId, orcid: entry.orcid)
                try newAuthor.save(db)
                author = newAuthor
            }
            try PaperAuthor(paperId: paperId, authorId: author.id, position: i).save(db)
        }
    }

    /// stub以外の全論文（追加日降順 → docs/09 3節の既定ソート）
    public func allPapers() throws -> [Paper] {
        try db.read { dbc in
            try Paper
                .filter(Column("is_stub") == false)
                .order(Column("added_at").desc)
                .fetchAll(dbc)
        }
    }

    public func paper(id: String) throws -> Paper? {
        try db.read { try Paper.fetchOne($0, key: id) }
    }

    public func authors(of paperId: String) throws -> [Author] {
        try db.read { dbc in
            try Author.fetchAll(dbc, sql: """
                SELECT authors.* FROM authors
                JOIN paper_authors ON paper_authors.author_id = authors.id
                WHERE paper_authors.paper_id = ?
                ORDER BY paper_authors.position
                """, arguments: [paperId])
        }
    }

    public func meta(of paperId: String) throws -> PaperMeta? {
        let path = layout.metaJSONPath(paperId)
        guard let data = FileManager.default.contents(atPath: path.path) else { return nil }
        return try PaperMeta.decode(from: data)
    }

    // MARK: - PDFの後付け（→ docs/04 6節, docs/09 4節）

    /// PDF未取得の論文へPDFを添付する（PDFタブのドロップ領域から）。
    /// pdf_hash重複を検出し、コピー後にハッシュを保存する。
    /// 呼び出し側は `completedStage: .fetch` のingestジョブを投入してconvert以降を再開すること。
    public func attachPDF(paperId: String, from source: URL) throws {
        guard let paper = try paper(id: paperId) else { throw LibraryError.paperNotFound(paperId) }
        let destination = layout.pdfPath(paperId)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw LibraryError.invalidLibrary("This paper already has a PDF")
        }
        let hash = try IngestPipeline.sha256(of: source)
        let duplicate = try db.read { dbc in
            try Paper.filter(Column("pdf_hash") == "sha256:\(hash)" && Column("id") != paperId).fetchOne(dbc)
        }
        if let duplicate {
            throw IngestError.duplicate(existingPaperId: duplicate.id)
        }
        try FileManager.default.createDirectory(at: layout.paperDir(paperId), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        var updated = paper
        updated.pdfHash = "sha256:\(hash)"
        let authorEntries = try authors(of: paperId).map {
            PaperMeta.AuthorEntry(displayName: $0.displayName, s2AuthorId: $0.s2AuthorId, orcid: $0.orcid)
        }
        try savePaper(updated, authors: authorEntries)
    }

    // MARK: - 補助ファイル（Supplementary等。フォルダの中身が正本 → docs/03 2節）

    /// 添付一覧（ファイル名順）。フォルダがなければ空
    public func supplements(of paperId: String) -> [URL] {
        let dir = layout.supplementsDir(paperId)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 添付の追加（コピー）。同名ファイルは「name 2.ext」のように連番を付ける
    @discardableResult
    public func addSupplement(paperId: String, from source: URL) throws -> URL {
        guard try paper(id: paperId) != nil else { throw LibraryError.paperNotFound(paperId) }
        let dir = layout.supplementsDir(paperId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var destination = dir.appendingPathComponent(source.lastPathComponent)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            destination = dir.appendingPathComponent(name)
            counter += 1
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// 添付の削除（ゴミ箱へ移動。復元可能 → docs/09 4節）
    public func removeSupplement(paperId: String, filename: String) throws {
        let target = layout.supplementsDir(paperId).appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.trashItem(at: target, resultingItemURL: nil)
    }

    // MARK: - ノート（正本: notes.md → docs/02, 09）

    public func saveNote(paperId: String, content: String) throws {
        guard try paper(id: paperId) != nil else { throw LibraryError.paperNotFound(paperId) }
        let dir = layout.paperDir(paperId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.data(using: .utf8)!.write(to: layout.notesPath(paperId), options: .atomic)
        try db.write { dbc in
            if var existing = try Note.filter(Column("paper_id") == paperId).fetchOne(dbc) {
                existing.content = content
                existing.updatedAt = PaperdDates.nowString()
                try existing.save(dbc)
            } else {
                try Note(paperId: paperId, content: content).save(dbc)
            }
        }
    }

    public func note(of paperId: String) -> String? {
        guard let data = FileManager.default.contents(atPath: layout.notesPath(paperId).path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 論文ID → 第一著者名（リストのソート・省略表記用 → docs/09 3節）
    public func firstAuthors() throws -> [String: String] {
        try db.read { dbc in
            var result: [String: String] = [:]
            let rows = try Row.fetchAll(dbc, sql: """
                SELECT pa.paper_id, a.display_name FROM paper_authors pa
                JOIN authors a ON a.id = pa.author_id WHERE pa.position = 0
                """)
            for row in rows { result[row["paper_id"]] = row["display_name"] }
            return result
        }
    }

    /// ノートを持つ論文ID集合（ダッシュボード統計用 → docs/09 4.2節）
    public func notedPaperIds() throws -> Set<String> {
        try db.read { dbc in
            Set(try String.fetchAll(dbc, sql: "SELECT DISTINCT paper_id FROM notes"))
        }
    }

    // MARK: - お気に入り・自著フラグ（正本はmeta.json → docs/02, 09 2.2節）

    public func setFavorite(_ paperId: String, _ value: Bool) throws {
        try setFlags(paperId) { $0.isFavorite = value }
    }

    public func setOwn(_ paperId: String, _ value: Bool) throws {
        try setFlags(paperId) { $0.isOwn = value }
    }

    func setFlags(_ paperId: String, _ mutate: (inout Paper) -> Void) throws {
        guard var paper = try paper(id: paperId) else { throw LibraryError.paperNotFound(paperId) }
        mutate(&paper)
        let authorEntries = try authors(of: paperId).map {
            PaperMeta.AuthorEntry(displayName: $0.displayName, s2AuthorId: $0.s2AuthorId, orcid: $0.orcid)
        }
        let override = try? meta(of: paperId)?.citationKeyOverride
        try savePaper(paper, authors: authorEntries, citationKeyOverride: override ?? nil)
    }

    // MARK: - 削除（→ docs/03 6節）

    /// 論文ディレクトリをゴミ箱へ移動し、DB行をCASCADE削除する。
    /// jobs行は削除前に取り除き（FK制約・履歴は保持しない）、
    /// どのエッジからも参照されなくなったstub行を掃除する（→ docs/03 6節）。
    public func deletePaper(id: String) throws {
        let dir = layout.paperDir(id)
        if FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
            } catch {
                // ゴミ箱が使えない環境（テスト等の一時ディレクトリ）では直接削除
                try FileManager.default.removeItem(at: dir)
            }
        }
        try db.write { dbc in
            try dbc.execute(sql: "DELETE FROM jobs WHERE paper_id = ?", arguments: [id])
            try Paper.deleteOne(dbc, key: id)
            // 孤児stubの掃除（引用エッジを失ったstubは存在意義がない）
            try dbc.execute(sql: """
                DELETE FROM papers WHERE is_stub = 1 AND id NOT IN (
                  SELECT citing_id FROM citations UNION SELECT cited_id FROM citations
                )
                """)
        }
    }

    // MARK: - インデックス再構築（→ docs/03 5節）

    /// papers/*/meta.json と collections.json からDBのメタデータ系テーブルを再投入する。
    /// チャンク・embeddingの再生成は呼び出し側がワーカーを使って行う（このメソッドは2・3段階のみ）。
    public func rebuildIndexFromFiles() throws {
        let fm = FileManager.default
        var metas: [PaperMeta] = []
        if let entries = try? fm.contentsOfDirectory(at: layout.papersDir, includingPropertiesForKeys: nil) {
            for dir in entries where dir.hasDirectoryPath && !dir.lastPathComponent.hasSuffix(".partial") {
                let metaPath = dir.appendingPathComponent("meta.json")
                guard let data = fm.contents(atPath: metaPath.path) else { continue }
                metas.append(try PaperMeta.decode(from: data))
            }
        }
        try db.write { dbc in
            try PaperAuthor.deleteAll(dbc)
            try Author.deleteAll(dbc)
            try Chunk.deleteAll(dbc)
            try dbc.execute(sql: "DELETE FROM vec_chunks")
            try dbc.execute(sql: "DELETE FROM fts_chunks")
            try Paper.deleteAll(dbc)

            for meta in metas {
                try meta.toPaper().save(dbc)
                try Self.replaceAuthors(dbc, paperId: meta.id, authors: meta.authors)
            }
        }
    }
}
