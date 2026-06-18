# 02. データモデル

SQLite（GRDB.swift、WALモード）。DBファイルは `~/PaperdLibrary/index/library.sqlite`。
**DBは再構築可能なインデックスであり、正本は各論文ディレクトリの `meta.json` 等のファイル**（→ [03](03-library-layout.md)）。

## 1. スキーマ

### papers — 論文

```sql
CREATE TABLE papers (
  id            TEXT PRIMARY KEY,        -- UUID v4
  title         TEXT NOT NULL,
  abstract      TEXT,
  year          INTEGER,
  venue         TEXT,                    -- 会議/誌名の表示用文字列
  doi           TEXT UNIQUE,
  arxiv_id      TEXT UNIQUE,             -- 例: 2403.01234 (バージョン番号は含めない)
  arxiv_version TEXT,                    -- 例: v2
  s2_paper_id   TEXT,                    -- Semantic Scholar paperId
  openalex_id   TEXT,
  bibtex_type   TEXT NOT NULL DEFAULT 'misc',  -- article / inproceedings / misc 等
  journal       TEXT,
  booktitle     TEXT,
  volume        TEXT,
  number        TEXT,
  pages         TEXT,
  publisher     TEXT,
  url           TEXT,
  bibtex_cached TEXT,                    -- 取得元提供の生BibTeX（あれば）
  pdf_hash      TEXT,                    -- SHA-256。重複検出用
  conversion_warnings INTEGER,           -- 変換品質検知の警告数（→ 05 4.1節）。NULL=未計算。paper.mdから再計算可能
  is_favorite   INTEGER NOT NULL DEFAULT 0,  -- お気に入り（正本はmeta.json → 03）
  is_own        INTEGER NOT NULL DEFAULT 0,  -- 自著論文（正本はmeta.json → 03）
  status        TEXT NOT NULL DEFAULT 'stub',
    -- stub | metadata_only | pdf_only | converting | indexed | failed
  is_stub       INTEGER NOT NULL DEFAULT 0,  -- 引用グラフ用の未取り込み論文
  added_at      TEXT NOT NULL,           -- ISO 8601
  updated_at    TEXT NOT NULL
);
CREATE INDEX idx_papers_status ON papers(status);
CREATE INDEX idx_papers_year   ON papers(year);
```

- `status` の遷移は取り込みパイプライン（→ [04](04-ingest-pipeline.md)）が管理
- `is_stub = 1` の行は引用グラフ表示のための書誌キャッシュ。ユーザが取り込みを指示すると `is_stub = 0` に昇格し、同一行のままパイプラインに乗る（→ [08](08-citation-graph.md)）
- stub行は `meta.json` を持たない（DBのみに存在し、再構築時はAPIから再取得）

### authors / paper_authors — 著者

```sql
CREATE TABLE authors (
  id            TEXT PRIMARY KEY,        -- UUID
  display_name  TEXT NOT NULL,
  s2_author_id  TEXT,
  orcid         TEXT
);
CREATE TABLE paper_authors (
  paper_id   TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
  author_id  TEXT NOT NULL REFERENCES authors(id),
  position   INTEGER NOT NULL,           -- 著者順 (0-based)
  PRIMARY KEY (paper_id, author_id)
);
```

著者の名寄せはv1では行わない（`s2_author_id` が一致する場合のみ同一行を再利用）。

### お気に入り・自著論文フラグ

論文の整理は `papers.is_favorite` / `papers.is_own` のフラグで行う（正本は `meta.json` → [03](03-library-layout.md)）。

> **設計変更（2026-06）**: 当初の階層コレクション機能（`collections` / `paper_collections` テーブル、
> `collections.json`）は**廃止**した。ユーザによる任意ルールの分類より、用途が明確な
> 「お気に入り」「自著論文」の2リストの方が実利用に合うため。テーブルはマイグレーションでDROPする。

### citations — 引用関係

```sql
CREATE TABLE citations (
  citing_id  TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
  cited_id   TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
  source     TEXT NOT NULL,              -- s2 | openalex
  fetched_at TEXT NOT NULL,
  PRIMARY KEY (citing_id, cited_id)
);
```

取得仕様・TTLは [08-citation-graph.md](08-citation-graph.md)。

### chunks / vec_chunks / fts_chunks — RAGインデックス

```sql
CREATE TABLE chunks (
  id           INTEGER PRIMARY KEY,      -- rowid
  paper_id     TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
  chunk_index  INTEGER NOT NULL,         -- 論文内の通し番号
  section_path TEXT,                     -- 例: "3. Method > 3.2 Training"
  text         TEXT NOT NULL,
  token_count  INTEGER NOT NULL
);
CREATE INDEX idx_chunks_paper ON chunks(paper_id);

-- ベクトルインデックス。chunks.id と rowid を一致させる。
-- 当初設計はsqlite-vec仮想テーブルだが、システム同梱のSQLiteは拡張をロードできないため、
-- v1は同一インターフェース（rowid = chunks.id）の通常テーブル + Swift側ブルートフォースKNN（VectorStore）で実装する。
-- sqlite-vec導入時はこのテーブル定義とVectorStoreのみ差し替える（設計変更 2026-06。→ [06](06-search-rag.md) 3節）
CREATE TABLE vec_chunks (
  rowid     INTEGER PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,
  embedding BLOB NOT NULL                -- Qwen3-Embedding: float32 × 1024次元
);

-- FTS5 仮想テーブル（キーワード検索用）
CREATE VIRTUAL TABLE fts_chunks USING fts5(
  text, content='chunks', content_rowid='id', tokenize='porter unicode61'
);

CREATE TABLE embedding_meta (            -- 再embedding判定用
  model_name  TEXT NOT NULL,             -- 例: mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ
  dimensions  INTEGER NOT NULL,
  created_at  TEXT NOT NULL
);
```

チャンキング・検索仕様は [06-search-rag.md](06-search-rag.md)。

### notes — ノート

```sql
CREATE TABLE notes (
  id          TEXT PRIMARY KEY,          -- UUID
  paper_id    TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
  content     TEXT NOT NULL,             -- Markdown
  page_anchor INTEGER,                   -- 関連PDFページ（任意）
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);
```

正本は `papers/{uuid}/notes.md`。v1ではノートは論文ごと1ファイルとし、`notes` テーブルはその索引（将来の複数ノート化に備えてテーブルは複数行可の設計）。

### jobs — ジョブキュー

```sql
CREATE TABLE jobs (
  id          TEXT PRIMARY KEY,          -- UUID
  kind        TEXT NOT NULL,             -- ingest | reindex | reconvert | refetch_citations 等
  paper_id    TEXT REFERENCES papers(id),
  payload     TEXT NOT NULL,             -- JSON（入力種別、URL等）
  status      TEXT NOT NULL DEFAULT 'queued',
    -- queued | running | succeeded | failed | cancelled
  stage       TEXT,                      -- resolve | fetch | convert | chunk | embed | index
  retry_count INTEGER NOT NULL DEFAULT 0,
  last_error  TEXT,
  origin      TEXT NOT NULL,             -- app | mcp | url_scheme
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);
CREATE INDEX idx_jobs_status ON jobs(status);
```

MCP/URLスキーム/アプリのすべての書き込み経路がこのキューを通る（→ [04](04-ingest-pipeline.md)）。

## 2. bibtex生成仕様

bibtexはDBフィールドから動的生成する。`bibtex_cached`（Crossref等の生BibTeX）があり、かつユーザ設定が「取得元優先」の場合はそれを返す（既定は動的生成）。

### 2.1 エントリタイプの決定

| 条件 | type |
|---|---|
| `journal` あり | `@article` |
| `booktitle` あり（会議録） | `@inproceedings` |
| arXivのみ（出版情報なし） | `@misc`（`eprint` / `archivePrefix={arXiv}` / `primaryClass` を付与） |
| その他 | `@misc` |

### 2.2 citation key 生成規則

```
{第一著者の姓(小文字, ASCII化)}{年}{タイトル先頭の内容語(小文字)}
例: vaswani2017attention
```

- 重複時は `a`, `b`, ... を末尾に付与
- ユーザによるkey手動編集を許可（`papers` に列追加はせず `meta.json` の `citation_key_override` で保持 → 再構築可能性を維持）

### 2.3 出力例

```bibtex
@inproceedings{vaswani2017attention,
  title     = {Attention Is All You Need},
  author    = {Vaswani, Ashish and Shazeer, Noam and ...},
  booktitle = {Advances in Neural Information Processing Systems},
  year      = {2017},
  url       = {https://...},
}
```

- 著者名は `姓, 名` 形式で ` and ` 連結
- LaTeX特殊文字（`& % # _ { }` 等）はエスケープ。非ASCII文字はそのまま出力（biblatex前提）し、設定でASCII変換モードを提供

### 2.4 引用文（citation）の生成

情報タブの「引用をコピー」で、書誌から**整形済みの引用文字列**を生成する（→ [09](09-ui.md) 4節）。

- **完全ローカル生成**（外部APIに頼らない。DOIのない論文・オフラインでも動作し、プライバシー原則とも整合）
- 対応スタイル: **APA 7 / MLA 9 / Chicago（著者-年）/ IEEE / Vancouver** の5種。
  CSLプロセッサの完全実装はv1スコープ外とし、ライブラリの主要エントリタイプ
  （journal / proceedings / arXivプレプリント / misc）に対する代表的な整形のみ提供する
- 出力はプレーンテキスト（イタリック等の書式は持たない。Word等への貼り付けを想定した近似）
- 著者名の姓/名分解はbibtex生成（2.2節）と同じ規則を共有する
- 既定スタイルはユーザ設定（最後に使ったスタイルを記憶）

## 3. マイグレーション方針

- GRDB.swift の `DatabaseMigrator` を使用し、起動時に自動適用
- `library.json` に `formatVersion` を持ち、ファイルレイアウト変更時はアプリがライブラリ移行を実行（→ [03](03-library-layout.md)）
- 破壊的なスキーマ変更はDB再構築（ファイルからのフル再インデックス）で代替できるため、複雑なデータ移行は書かない方針
