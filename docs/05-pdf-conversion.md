# 05. PDF変換（Docling）とワーカーAPI

学術PDFをAIフレンドリーなMarkdown + 構造化JSONへ変換する。実行主体はPythonワーカー（→ [01](01-architecture.md) 3節）、呼び出し元はJobRunnerのconvertステージ（→ [04](04-ingest-pipeline.md)）。

## 1. 変換方式の比較と採用根拠

| 候補 | ライセンス | 2段組/表/数式 | 備考 | 判定 |
|---|---|---|---|---|
| **Docling** | MIT | ◎（レイアウトモデルで対応） | DoclingDocument構造化出力 + Markdown。Apple Silicon MPS対応。IBM主導で開発が活発 | **採用** |
| marker | GPL + 商用利用条件 | ◎ | 品質は高いがライセンスが配布形態（→ [01](01-architecture.md) 7節）と相性が悪い | 不採用 |
| GROBID | Apache-2.0 | ○（書誌・参考文献抽出に特化） | 書誌はAPI（Crossref等）から取得するため強みが活きない。Javaサーバ常駐が重い | 不採用 |
| pymupdf4llm | AGPL | △（2段組で読み順が破綻しやすい） | 高速・軽量だが学術PDFに不向き。AGPLも障壁 | 不採用 |

採用理由の要点:

1. **MITライセンス** — Developer ID直接配布・将来の商用化と矛盾しない
2. **学術PDF特化の構造認識** — 2段組の読み順、表、数式（LaTeX出力）に対応
3. **構造化出力（DoclingDocument）** — セクション階層を保持したJSONが得られ、チャンキング（→ [06](06-search-rag.md)）の品質を決定づける
4. **MPS加速** — Apple Silicon専用（→ [00](00-overview.md)）の前提と合致

## 2. 出力形式

1論文につき2ファイルを `papers/{uuid}/` に書き出す（→ [03](03-library-layout.md)）。

| ファイル | 用途 | 内容 |
|---|---|---|
| `paper.md` | 人間の閲覧・LLMへの全文提供（MCP `fulltext`） | 見出し階層付きMarkdown |
| `paper.docling.json` | チャンク再生成・インデックス再構築 | DoclingDocument（セクション階層・要素種別・ページ番号を保持） |

- **数式**: LaTeX形式（`$...$` / `$$...$$`）
- **表**: Markdownテーブル
- **図**: v1では画像抽出しない。`<!-- image -->` プレースホルダのみ（v2候補 → [10](10-roadmap-risks.md)）

## 3. ワーカーHTTP API

127.0.0.1 ランダムポート + `Authorization` トークンの枠組み（→ [01](01-architecture.md) 3.1節）に従う。embedding API（4.2節）は [06](06-search-rag.md) から参照される。

### 3.1 POST /convert

```json
// リクエスト
{ "pdf_path": "/Users/.../papers/{uuid}/paper.pdf",
  "output_dir": "/Users/.../papers/{uuid}",
  "options": { "ocr": false, "max_pages": 500, "timeout_sec": 900,
               "force_ocr": false, "formula_enrichment": false } }

// レスポンス（202）
{ "job_id": "w-3f9a..." }
```

変換は非同期。完了時に `paper.md` / `paper.docling.json` を `output_dir` へ書き出す（大きな本文をHTTPで往復させない）。

- `force_ocr`: 全ページを強制OCR。PDFのフォント→Unicode対応表（ToUnicode CMap）が壊れた文書の文字化け（例: ≈ が ¼ になる）をピクセルからの再読取で回復する。OCRエンジンは**macOSのVisionフレームワーク（ocrmac）**を使用（Apple Silicon専用の前提と合致し、モデルダウンロード不要で軽量）
- `formula_enrichment`: 数式エンリッチメント（ローカルモデル）。数式・上付き/下付き文字をLaTeXとして抽出する（例: 10³ が 103 に潰れる問題への対処）
- 両オプションとも処理時間が数倍になるため**既定はオフ**。高精度再変換（→ 6節）でのみ有効化する

### 3.2 GET /jobs/{id}

```json
{ "job_id": "w-3f9a...",
  "status": "running",            // queued | running | succeeded | failed
  "stage": "layout",              // load | ocr | layout | table | export
  "progress": { "page": 12, "total_pages": 34 },
  "error": null }
```

JobRunnerは2秒間隔でポーリングし、UIのページ進捗表示に反映する（→ [09](09-ui.md)）。

### 3.3 POST /embed

```json
// リクエスト
{ "texts": ["chunk text 1", "chunk text 2"],
  "task": "passage" }             // passage（索引時） | query（検索時）

// レスポンス
{ "embeddings": [[0.012, ...], [0.034, ...]], "model": "BAAI/bge-m3", "dimensions": 1024 }
```

### 3.4 GET /health

```json
{ "status": "ok", "model_loaded": true, "version": "0.2.1" }
```

### 3.5 エラー応答

HTTPステータス + 共通ボディで返す。

```json
{ "error": { "code": "PDF_ENCRYPTED", "message": "PDF is password-protected" } }
```

| code | 意味 | リトライ |
|---|---|---|
| `PDF_CORRUPT` / `PDF_ENCRYPTED` | 破損・暗号化PDF | しない（恒久的エラー） |
| `PAGE_LIMIT_EXCEEDED` | `max_pages` 超過 | しない（ユーザに上限引き上げを案内） |
| `TIMEOUT` | `timeout_sec` 超過 | しない |
| `MODEL_NOT_READY` | モデル未ダウンロード | セットアップ誘導（→ [01](01-architecture.md) 3.3節） |
| `INTERNAL` | その他 | バックオフリトライ対象（→ [04](04-ingest-pipeline.md) 7節） |

## 4. 変換品質の限界と対策

| ケース | 対策 |
|---|---|
| **変換ミスの見逃し**（読み順崩れ・本文欠落・文字化け等。AIはMCP経由でMarkdownを読むため、誤った本文を参照し続ける） | 3段構え: ①**変換品質検知**（4.1節）で疑わしい論文を自動フラグ、②詳細ペインの**Markdownタブ**でPDFと見比べて確認（→ [09](09-ui.md) 4節）、③**高精度再変換**（5.1節）と**MCP経由の修正**（5.2節, → [07](07-mcp-server.md)）で修復 |
| スキャンPDF（テキスト層なし） | DoclingのOCRオプションで対応可能。**v1の既定はオフ**（処理時間が大幅増のため）。設定で有効化でき、変換失敗時にUIが「OCRを試す」を提案 |
| 破損・暗号化PDF | 即 `failed`。`metadata_only` 相当として書誌は保持 |
| 巨大PDF（書籍・プロシーディング全体） | `max_pages`（既定500）と `timeout_sec`（既定900秒）で打ち切り。超過時はユーザ確認の上で上限を引き上げて再実行可能 |
| 複雑な表・図中テキスト | 完全再現は保証しない。原文確認はPDFビューアで行う前提（→ [09](09-ui.md)） |

### 4.1 変換品質検知（ヒューリスティック）

変換完了時（chunkステージ）に `paper.md` を走査し、機械的に検出できる文字化けの兆候を数える。
結果は `papers.conversion_warnings`（→ [02](02-data-model.md)）にキャッシュし、UIでバッジ表示する（→ [09](09-ui.md)）。

| パターン | 兆候 |
|---|---|
| `(cid:NNN)` | フォントのUnicode対応欠落（テキスト抽出の典型的失敗） |
| U+FFFD（置換文字）、私用領域（PUA）文字 | グリフをUnicodeへ解決できていない |
| 分数・記号の不自然な出現（¼ ½ ¾ ⅓ ⅔ 等が本文に散在） | ToUnicode CMap破損による別グリフへの誤対応 |
| 未正規化の合字（ﬁ ﬂ ﬀ 等） | 抽出時の正規化漏れ（検索一致にも悪影響） |
| **ラテン文字主体の文書中のキリル同形字**（例: PbTiO3 が РЬТіОз になる） | OCRの同形字混同（force_ocr使用時に発生しうる。検索一致を阻害） |

検出は安価なため全論文に適用する。意味的な誤り（10³ → 103 等の上付き潰れ）は機械検出できないため、
Markdownタブでの目視とMCP修正（→ [07](07-mcp-server.md)）に委ねる。

## 5. 高精度再変換と修正Markdown

### 5.1 高精度再変換（reconvertジョブ）

Markdownタブの「高精度で再変換」から、対象論文のみ `force_ocr` + `formula_enrichment` を有効にして
変換し直す（`jobs.kind = 'reconvert'` → [02](02-data-model.md)）。convert以降のステージ
（convert → chunk → embed → index）を再実行し、`paper.md` / `paper.docling.json` を上書きする。
**既存の修正（`paper.corrected.md`）は基底テキストが変わるため破棄**し、履歴（`paper.corrections.json`）に
その旨を記録する（古い修正が新しい変換結果を隠し続けるのを防ぐ）。
処理時間が数倍になるため全論文への適用はせず、ユーザが重要論文を選んで実行する。

### 5.2 修正Markdownオーバーレイ（paper.corrected.md）

機械的変換で直らない意味的な誤りは、ユーザがMCP経由で高性能LLMに修正させる
（`apply_fulltext_patches` → [07](07-mcp-server.md)）。

- 修正は `paper.corrected.md` に保存し、**Docling出力（`paper.md`）は不変のまま残す**（→ [03](03-library-layout.md)）
- 修正履歴（日時・パッチ内容・注記）は `paper.corrections.json` に追記する
- `paper.corrected.md` が存在する論文では、MCP `get_fulltext`・チャンキング（RAGインデックス）・
  Markdownタブの表示すべてが修正版を優先する（**有効Markdown**と呼ぶ）
- 修正の取り消しは `paper.corrected.md` の削除（= Docling出力へ戻る）

## 6. 性能目安

Apple Silicon + MPS加速を前提とする。

| 条件 | 目安 |
|---|---|
| 標準的な会議論文（10ページ前後） | 30秒〜1分 |
| 長編（50ページ以上、表多数） | 数分 |
| 初回（モデルロード含む） | +10〜20秒 |

convertジョブは直列1本（→ [04](04-ingest-pipeline.md) 8節）のため、大量一括取り込み時はキュー待ちが発生する。UIで残りジョブ数を表示する。
