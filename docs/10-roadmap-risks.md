# 10. ロードマップ・リスク・未決事項

## 1. v1 スコープ（確定）

[00-overview.md](00-overview.md) 2節の「含むもの」一覧の通り。実装順の目安:

| フェーズ | 内容 | マイルストーン |
|---|---|---|
| M1: 基盤 | PaperdCore（DB / マイグレーション / meta.json入出力）、ライブラリレイアウト、最小UI（リスト表示） | PDFを手動配置してリスト表示できる |
| M2: 取り込み | メタデータ解決（arXiv / Crossref / S2 / OpenAlex）、jobsキュー、JobRunner | arXiv ID / DOI / PDFドロップで書誌登録できる |
| M3: AI処理 | Pythonワーカー（venv + pip セットアップ / Docling / Qwen3-Embedding MLX）、チャンキング、インデックス投入 | 取り込んだ論文がMarkdown化・embedding済みになる |
| M4: 検索 | ハイブリッド検索（ベクトルKNN + FTS5 + RRF）、検索UI、PDFビューア | アプリ内でSemantic検索→PDF閲覧が通る |
| M5: MCP | paperd-mcp（5ツール）、設定スニペットUI | ClaudeからライブラリをSemantic検索・bibtex取得できる |
| M6: 周辺機能 | 引用グラフ、ノート、初回セットアップウィザード磨き込み | v1リリース候補 |

## 2. v2 候補

| 候補 | 概要 | 関連ドキュメント |
|---|---|---|
| マルチデバイス同期 | iCloud Drive等でのライブラリ同期。meta.json競合マージ、`index/` 除外運用の自動化 | [03](03-library-layout.md) 4節 |
| ブラウザ取り込み | 第1段階: メニューバー常駐 + AppleScriptによるタブURL取得。第2段階: WebExtension + localhost HTTP送信で認証付き（学内プロキシ等）PDFも取得。設計案あり | [11](11-browser-capture.md) |
| PDF注釈・ハイライト | PDFKitの注釈APIで作成・保存。注釈テキストのRAG対象化 | [09](09-ui.md) |
| ライブラリ全体グラフ | エゴネットワークではなく全論文の引用グラフ俯瞰 | [08](08-citation-graph.md) |
| Docling軽量化 | PDF変換側の依存・メモリ負荷をさらに抑える。embeddingはQwen3-Embedding MLXへ移行済み | [05](05-pdf-conversion.md), [06](06-search-rag.md) |
| MCPワーカー自走 | アプリ非起動時もMCPプロセスが変換・embeddingまで完遂するオプション | [07](07-mcp-server.md) |
| 推薦・関連論文 | embedding近傍 + 引用グラフを使った「次に読むべき論文」提示 | — |

## 3. リスク一覧

| # | リスク | 影響 | 対策 |
|---|---|---|---|
| R1 | Python環境のサイズと初回セットアップの失敗 | 初回体験の悪化、サポート負荷 | embeddingはQwen3-Embedding MLXで軽量化済み。Docling等の残る依存はセットアップウィザードで進捗・中断再開・オフライン明示（[09](09-ui.md)） |
| R2 | Swift MCP SDKのメンテナンス停滞（公式が2025年末から流動的） | MCPサーバの保守困難 | 薄いアダプタ層でSDK差し替え可能に。最悪stdio JSON-RPC自前実装（[07](07-mcp-server.md)） |
| R3 | MCPからの `add_paper` がアプリ非起動時に変換まで進まない | AIエージェントから見ると取り込みが「保留」になる | ツール応答でその旨を明示（[07](07-mcp-server.md)）。v2でワーカー自走オプション |
| R4 | Semantic Scholar APIのレートリミット（キーなしでは厳しい） | 引用グラフ・メタデータ補完の遅延 | 設定でAPIキー登録を推奨。OpenAlexフォールバック（[08](08-citation-graph.md)） |
| R5 | ブルートフォースKNNのスケール上限 | 数十万チャンク超で検索が遅延 | 個人ライブラリ規模（数千論文）では問題なし。閾値超過時のsqlite-vec/LanceDB等への移行パスを未決事項として保持 |
| R6 | 数式中心の検索品質（embeddingは数式・記号に弱い） | 一部クエリの検索精度低下 | FTS5ハイブリッドで部分緩和。限界として明記（[06](06-search-rag.md)） |
| R7 | Doclingの変換失敗（スキャンPDF・特殊レイアウト） | 一部論文が全文検索不可 | `pdf_only` ステータスで部分的成功を許容。OCRオプション・手動再試行（[04](04-ingest-pipeline.md), [05](05-pdf-conversion.md)） |

## 4. 未決事項

| # | 事項 | 決定の期限 |
|---|---|---|
| U1 | Swift MCP SDKの具体的な採用先（公式 / コミュニティフォーク） | M5着手時に再評価 |
| U2 | ベクトルストアのLanceDB移行閾値と移行手順の詳細 | 実利用でR5が顕在化した時点 |
| U3 | Qwen3-Embeddingのbatch size / cache解放ポリシーの最適値 | 実利用で再embedding速度とメモリのバランスを評価 |
| U4 | Sparkle（自動更新）の導入時期 | v1リリース判断時 |
| U5 | meta.json競合マージの具体仕様 | v2同期設計時 |
