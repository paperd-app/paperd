import Foundation
import GRDB

/// `~/PaperdLibrary/index/library.sqlite` へのアクセス（→ docs/02-data-model.md）。
/// DBは再構築可能なインデックスであり、正本はライブラリ内のファイル（→ docs/03-library-layout.md）。
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    /// WALモード + busy_timeout 5000ms（→ docs/01-architecture.md 5節）
    public init(path: String) throws {
        var config = Configuration()
        config.busyMode = .timeout(5.0)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let pool = try DatabasePool(path: path, configuration: config)
        self.writer = pool
        try Self.migrator.migrate(pool)
    }

    /// テスト用インメモリDB
    public init(inMemory: Bool) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let queue = try DatabaseQueue(configuration: config)
        self.writer = queue
        try Self.migrator.migrate(queue)
    }

    public var reader: any DatabaseReader { writer }

    public func read<T>(_ block: (Database) throws -> T) throws -> T {
        try reader.read(block)
    }

    public func write<T>(_ block: (Database) throws -> T) throws -> T {
        try writer.write(block)
    }

    /// スキーマv1（→ docs/02-data-model.md 1節）
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE papers (
              id            TEXT PRIMARY KEY,
              title         TEXT NOT NULL,
              abstract      TEXT,
              year          INTEGER,
              venue         TEXT,
              doi           TEXT UNIQUE,
              arxiv_id      TEXT UNIQUE,
              arxiv_version TEXT,
              s2_paper_id   TEXT,
              openalex_id   TEXT,
              bibtex_type   TEXT NOT NULL DEFAULT 'misc',
              journal       TEXT,
              booktitle     TEXT,
              volume        TEXT,
              number        TEXT,
              pages         TEXT,
              publisher     TEXT,
              url           TEXT,
              bibtex_cached TEXT,
              pdf_hash      TEXT,
              status        TEXT NOT NULL DEFAULT 'stub',
              is_stub       INTEGER NOT NULL DEFAULT 0,
              added_at      TEXT NOT NULL,
              updated_at    TEXT NOT NULL
            );
            CREATE INDEX idx_papers_status ON papers(status);
            CREATE INDEX idx_papers_year   ON papers(year);

            CREATE TABLE authors (
              id            TEXT PRIMARY KEY,
              display_name  TEXT NOT NULL,
              s2_author_id  TEXT,
              orcid         TEXT
            );
            CREATE TABLE paper_authors (
              paper_id   TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
              author_id  TEXT NOT NULL REFERENCES authors(id),
              position   INTEGER NOT NULL,
              PRIMARY KEY (paper_id, author_id)
            );

            CREATE TABLE collections (
              id         TEXT PRIMARY KEY,
              name       TEXT NOT NULL,
              parent_id  TEXT REFERENCES collections(id),
              sort_order INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE paper_collections (
              paper_id      TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
              collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
              PRIMARY KEY (paper_id, collection_id)
            );

            CREATE TABLE citations (
              citing_id  TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
              cited_id   TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
              source     TEXT NOT NULL,
              fetched_at TEXT NOT NULL,
              PRIMARY KEY (citing_id, cited_id)
            );

            CREATE TABLE chunks (
              id           INTEGER PRIMARY KEY,
              paper_id     TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
              chunk_index  INTEGER NOT NULL,
              section_path TEXT,
              text         TEXT NOT NULL,
              token_count  INTEGER NOT NULL
            );
            CREATE INDEX idx_chunks_paper ON chunks(paper_id);

            -- 設計書ではsqlite-vec仮想テーブル。システムSQLiteは拡張ロード不可のため、
            -- v1は同一インターフェース（rowid = chunks.id）の通常テーブル + Swift側ブルートフォースKNNで実装。
            -- sqlite-vec導入時はこのテーブル定義とVectorStoreの実装のみ差し替える。
            CREATE TABLE vec_chunks (
              rowid     INTEGER PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,
              embedding BLOB NOT NULL
            );

            CREATE VIRTUAL TABLE fts_chunks USING fts5(
              text, content='chunks', content_rowid='id', tokenize='porter unicode61'
            );

            CREATE TABLE embedding_meta (
              model_name  TEXT NOT NULL,
              dimensions  INTEGER NOT NULL,
              created_at  TEXT NOT NULL
            );

            CREATE TABLE notes (
              id          TEXT PRIMARY KEY,
              paper_id    TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
              content     TEXT NOT NULL,
              page_anchor INTEGER,
              created_at  TEXT NOT NULL,
              updated_at  TEXT NOT NULL
            );

            CREATE TABLE jobs (
              id          TEXT PRIMARY KEY,
              kind        TEXT NOT NULL,
              paper_id    TEXT REFERENCES papers(id),
              payload     TEXT NOT NULL,
              status      TEXT NOT NULL DEFAULT 'queued',
              stage       TEXT,
              retry_count INTEGER NOT NULL DEFAULT 0,
              last_error  TEXT,
              origin      TEXT NOT NULL,
              created_at  TEXT NOT NULL,
              updated_at  TEXT NOT NULL
            );
            CREATE INDEX idx_jobs_status ON jobs(status);
            """)
        }
        // 変換品質検知の警告数キャッシュ（→ docs/02, docs/05 4.1節）。paper.mdから再計算可能
        migrator.registerMigration("v2") { db in
            try db.execute(sql: "ALTER TABLE papers ADD COLUMN conversion_warnings INTEGER")
        }
        // コレクション廃止 + お気に入り/自著フラグ（→ docs/02 設計変更メモ）。
        // フラグの正本はmeta.json（再構築で復元可能）
        migrator.registerMigration("v3") { db in
            try db.execute(sql: """
                DROP TABLE IF EXISTS paper_collections;
                DROP TABLE IF EXISTS collections;
                ALTER TABLE papers ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE papers ADD COLUMN is_own INTEGER NOT NULL DEFAULT 0;
                """)
        }
        return migrator
    }
}
