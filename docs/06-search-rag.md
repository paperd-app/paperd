# 06. 検索とRAG

全文のチャンキング・embedding・ハイブリッド検索の仕様。インデックスのスキーマは [02](02-data-model.md)、embedding生成APIは [05](05-pdf-conversion.md) 3.3節。

## 1. Embeddingモデル選定

**Qwen3-Embedding-0.6B 4bit（MLX版: `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`）** を採用する。

| 観点 | Qwen3-Embedding-0.6B 4bit | multilingual-e5-large | nomic-embed-text-v2-moe |
|---|---|---|---|
| 多言語（日→英の言語横断） | ◎ | ◎ | ○ |
| 最大トークン | 32768 | 512 | 512 |
| 次元 | 1024 | 1024 | 768 |
| 備考 | 小型・高品質・MLXで常駐メモリを抑えやすい | トークン制限が512チャンク前提でも窮屈 | MoEで推論コスト面の不確実性 |

採用理由:

1. **言語横断検索** — 「日本語クエリ → 英語論文」がコア体験。Qwen3-Embeddingは多言語dense検索で安定し、実データ評価でも日本語表現差に強い
2. **軽量な常駐** — 4bit MLX版はモデルキャッシュが約335MBで、文献管理アプリの常駐機能として扱いやすい
3. **1024次元** — `vec_chunks` の `float[1024]` と対応（→ [02](02-data-model.md)）。数千論文規模でインデックスサイズが現実的

ランタイムは**Pythonワーカー内の MLX**。ワーカーの `/embed` API（→ [05](05-pdf-conversion.md)）で抽象化しているため、呼び出し側（Swift）はモデル実装に依存しない。

## 2. チャンキング

`paper.docling.json` のセクション構造を使い、**セクション境界を尊重して分割**する（DoclingのHybridChunker相当）。プレーンMarkdownの機械分割より文脈の切断が少ない。

| パラメータ | 値 |
|---|---|
| 目安サイズ | 約512トークン（モデル非依存の近似値） |
| オーバーラップ | 15% |
| メタデータ | `section_path`（例: `"3. Method > 3.2 Training"`）を `chunks` 行に付与 |

> `chunks.token_count` に保存する値は近似（単語数と文字数÷4 の最大値。
> `Chunker.estimateTokens`）で、Qwen3 tokenizerの厳密なトークン数ではない。
> チャンク分割の判定に使う概算値であり、検索品質には影響しない。

ルール:

- **参考文献・謝辞セクションは除外**（検索ノイズの主因）
- **タイトル + アブストラクトは独立チャンクとして必ず索引化**する（`pdf_only` 以外の全論文で書誌から生成。PDF未取得の `metadata_only` 論文もこれによりsemantic検索にヒットする）
- **ノート（`notes.md`）もチャンク対象**。ユーザのメモ経由で論文を発見できる
- 表はMarkdownテーブルのまま1チャンクに収め、超過時のみ行単位で分割
- **ハードキャップ（強制分割）**: 段落境界で分割できない巨大ブロック（数式エンリッチ由来の
  1行数千文字のLaTeX等）も、`targetTokens × 1.25` を超えるチャンクは文字数ベースで強制分割する。
  Transformer attentionは系列長の2乗で計算量・メモリが増えるため、2,000トークン級のチャンクは
  embeddingが桁違いに重く、システム全体の低速化を招く

## 3. インデックス

| インデックス | 実体 | 方式 |
|---|---|---|
| ベクトル | `vec_chunks`（通常テーブル、float32 BLOB） | `VectorStore`（Swift）でブルートフォースKNN。当初設計のsqlite-vecはシステムSQLiteが拡張をロードできないため使わず、embeddingを `float[1024]` のBLOBとして保持し全走査する。数千論文 ≒ 数十万チャンク規模なら全走査でも検索応答 < 1秒（→ [00](00-overview.md)）を満たし、ANN導入の複雑さも回避できる。`rowid = chunks.id` の界面はsqlite-vec採用時と同一なので、将来は型の差し替えのみで移行できる（設計変更 2026-06） |
| キーワード | `fts_chunks`（FTS5） | `porter unicode61` トークナイザ |

`chunks.id` = `vec_chunks.rowid` = `fts_chunks.rowid` を一致させ、JOINなしで突き合わせる。

## 4. ハイブリッド検索

semantic検索とキーワード検索を **RRF（Reciprocal Rank Fusion）** で統合する。

1. クエリをembedding化し、`vec_chunks` から semantic top-k（既定50）を取得
2. 同じクエリで `fts_chunks` から FTS5 top-k（既定50）を取得
3. RRF（`k = 60`）で統合: `score(c) = Σ 1 / (k + rank_i(c))`
4. 上位N件（UI既定20、MCPはツール引数）を返す

- 同一論文のチャンクが上位を占有しないよう、論文ごとの最大表示チャンク数（既定3）でグルーピングする

### 検索結果スキーマ

UI / MCP共通（→ [07](07-mcp-server.md)）。

```json
{
  "results": [
    { "paper_id": "8f14e45f-...",
      "title": "Attention Is All You Need",
      "year": 2017,
      "section_path": "3. Method > 3.2 Attention",
      "chunk_text": "...",
      "score": 0.0312,            // RRF統合スコア（順位ベース。相対比較のみに使う）
      "match_type": "hybrid",     // semantic | keyword | hybrid
      "semantic_score": 0.72,     // semantic側のコサイン類似度（semantic/hybrid時のみ）
      "keyword_rank": 1 }         // FTS5順位（1始まり。keyword/hybrid時のみ）
  ]
}
```

## 5. クエリembeddingの生成経路

| 呼び出し元 | ワーカー | 備考 |
|---|---|---|
| アプリUI | 常駐ワーカー | 初回ジョブ実行時に起動済み。検索レイテンシ最小 |
| MCPサーバ | オンデマンド起動（既存ワーカーがいれば `worker.lock` 経由で再利用） | 初回はモデルロード待ちが発生。アイドル10分で自動終了（→ [01](01-architecture.md) 3.2節） |

`/embed` は `task: "query"` で呼ぶ（索引時は `"passage"`）。

## 6. 再embedding

- 起動時に `embedding_meta`（→ [02](02-data-model.md)）と設定中のモデル名・次元を比較し、**不一致なら全チャンクの再embedをバックグラウンドジョブ**（`jobs.kind = reindex`）として投入する
- チャンク本文（`chunks` / `fts_chunks`）は再利用し、`vec_chunks` のみ再計算。`paper.docling.json` からのチャンク再生成は不要
- モデル変更UI: 設定画面で変更時に「全N論文の再計算が必要（推定M分）」を提示して確認。実行中も旧embeddingで検索可能とし、論文単位で順次置き換える
- インデックス再構築（→ [03](03-library-layout.md) 5節）も同じ経路を使う

## 7. 検索品質の限界

- **数式中心のクエリは弱い**。embeddingは数式の意味をほぼ捉えられず、LaTeX文字列の字面一致（FTS5）で部分的に緩和されるのみ。v1の既知の制約として明記する（→ [10](10-roadmap-risks.md)）
- `pdf_only` 論文は書誌チャンクがないため、タイトル一致での発見性が本文チャンク頼みになる（手動解決を促す → [04](04-ingest-pipeline.md) 4節）
- FTS5の `porter` ステマーは英語前提。日本語ノートのキーワード検索はunicode61のbigramなし分割となり精度が落ちる（semantic側で補完）
