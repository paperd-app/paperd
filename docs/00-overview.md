# 00. 概要と要件定義

paperd — 学術研究向け論文管理ソフトウェア 設計書

## 1. 目的

研究者が日常的に読む学術論文を一元管理し、**ローカルAIによる全文Semantic検索**と**MCP経由でのAI連携**を中核機能として提供するmacOSネイティブアプリケーションを開発する。

既存ツール（Zotero, Mendeley等）との差別化点:

- 論文全文（PDF + AIフレンドリーなMarkdown）をRAG化し、自然言語で「あの手法について書いてあった論文」を探せる
- MCPサーバを介して、Claude等のAIエージェントがユーザのライブラリを直接検索・参照・追加できる
- AI処理（embedding生成・PDF構造解析）は**完全ローカル実行**。論文データを外部に送信しない

## 2. スコープ（v1）

### 含むもの

| 機能 | 概要 |
|---|---|
| 論文取り込み | arXiv ID / DOI / PDFファイルドロップからの取り込み |
| メタデータ解決 | arXiv API, Crossref, Semantic Scholar, OpenAlex からの書誌情報取得 |
| 2形式保持 | オリジナルPDF + Markdown（Docling変換）をライブラリに保存 |
| Semantic検索 | 全文RAG化（bge-m3 + sqlite-vec）、FTS5キーワード検索とのハイブリッド |
| bibtex出力 | メタデータからの動的生成。UI / MCP双方から取得可能 |
| MCPサーバ | 検索・bibtex・全文取得・論文追加の5ツールを提供（→ [07](07-mcp-server.md)） |
| PDFビューア | PDFKitによるアプリ内閲覧 |
| 引用関係グラフ | 選択論文を中心とした引用・被引用のエゴネットワーク表示（→ [08](08-citation-graph.md)） |
| お気に入り・自著論文 | フラグによる論文リスト（サイドバーから選択）。自著リストは被引用ネットワークの可視化つき（→ [09](09-ui.md)） |

### 含まないもの（v2以降の候補。→ [10](10-roadmap-risks.md)）

- マルチデバイス同期（ただしデータ設計では考慮する。→ [03](03-library-layout.md)）
- PDF注釈・ハイライトの作成
- ライブラリ全体の引用グラフ表示
- ブラウザからのワンクリック取り込み（メニューバー方式・ブラウザ拡張とも。設計案: [11](11-browser-capture.md)）
- Windows / Linux / iOS対応

## 3. 確定要件

1. macOSネイティブアプリ（Swift / SwiftUI）。Apple Silicon専用
2. 論文データは オリジナルPDF と AIフレンドリー形式（Markdown + 構造化JSON）の2種類で保持
3. 論文データ全体をRAG化し、アプリUIおよびMCPサーバ経由でSemantic検索可能
4. bibtex情報をアプリUIおよびMCPサーバ経由で取得可能
5. AI処理は完全ローカル実行（embedding・PDF変換で外部APIを使わない）
6. メタデータ・PDF取得ソース: arXiv / Crossref (DOI) / Semantic Scholar / OpenAlex
7. v1は単一Macローカル完結。将来のファイル同期を見据えたポータブルなデータ設計とする

## 4. 非機能要件

| 項目 | 要件 |
|---|---|
| プライバシー | 論文本文・ノートを外部送信しない。外部通信はメタデータAPI・PDF取得のみ。**例外**: MCP経由でユーザが接続したAIクライアントへのツール応答（`get_fulltext` / 変換修正 → [07](07-mcp-server.md)）はユーザの明示的な操作によるオプトインとみなす |
| ポータビリティ | ライブラリはファイルが正本。SQLiteインデックスは全再構築可能（→ [03](03-library-layout.md)） |
| 性能目標 | 検索応答 < 1秒（数千論文規模）。取り込み（変換+embedding）は1論文あたり数十秒〜数分を許容（非同期実行） |
| 耐障害性 | 取り込みパイプラインはステージ単位で再開可能（→ [04](04-ingest-pipeline.md)） |
| 配布 | Developer ID + notarization による直接配布。App Storeは対象外（→ [01](01-architecture.md)） |

## 5. 用語集

| 用語 | 定義 |
|---|---|
| ライブラリ | ユーザの全論文データを格納するディレクトリ（`~/PaperdLibrary`）。ファイルが正本 |
| インデックス | ライブラリから再構築可能なSQLiteデータベース（FTS5 / sqlite-vec含む） |
| paper | ライブラリ内の1論文。UUIDで識別 |
| stub論文 | 引用グラフ用に書誌情報のみ保持する未取り込み論文（`papers.is_stub = 1`） |
| チャンク | RAG検索の単位となる本文の断片（セクション境界を尊重、約512トークン） |
| ジョブ | 取り込みパイプラインの実行単位。`jobs`テーブルで永続化 |
| ワーカー | PDF変換とembedding生成を担うPythonプロセス（Docling + sentence-transformers） |
| MCPサーバ | `paperd-mcp`。stdioで動作するSwift製CLI。アプリ非起動時も動作可能 |
| 解決（resolve） | 入力（arXiv ID / DOI / PDF / URL）から正規の書誌メタデータを確定する処理 |

## 6. ドキュメント構成

| ファイル | 内容 |
|---|---|
| [01-architecture.md](01-architecture.md) | プロセス構成・IPC・Python環境・配布 |
| [02-data-model.md](02-data-model.md) | SQLiteスキーマ・bibtex生成仕様 |
| [03-library-layout.md](03-library-layout.md) | フォルダ構造・meta.json・再構築可能性 |
| [04-ingest-pipeline.md](04-ingest-pipeline.md) | 取り込みステートマシン・jobsキュー |
| [05-pdf-conversion.md](05-pdf-conversion.md) | Docling変換・ワーカーAPI仕様 |
| [06-search-rag.md](06-search-rag.md) | embedding・チャンキング・ハイブリッド検索 |
| [07-mcp-server.md](07-mcp-server.md) | MCPツール定義・書き込み設計 |
| [08-citation-graph.md](08-citation-graph.md) | 引用データ取得・グラフ表示 |
| [09-ui.md](09-ui.md) | 画面構成・PDFビューア・検索UI |
| [10-roadmap-risks.md](10-roadmap-risks.md) | ロードマップ・リスク・未決事項 |
| [11-browser-capture.md](11-browser-capture.md) | ブラウザからのワンクリック取り込み（**v2設計案**。v1では実装しない） |
