# paperd

## インストール

```sh
brew install --cask paperd-app/paperd/paperd   # 推奨（uvも自動で入ります）
```

または [GitHub Releases](https://github.com/paperd-app/paperd/releases) からzipを直接ダウンロード。
初回起動後、設定 > ワーカー から「環境構築」を実行してください（数分・2〜3GB）。

## ライセンス

[FSL-1.1-Apache-2.0](LICENSE.md)（Functional Source License）。
個人利用・研究・教育・社内利用は自由です。競合する商用製品としての再配布のみ制限され、
各リリースは公開から2年でApache 2.0に自動転換されます。

学術研究向け論文管理ソフトウェア（設計書: [docs/](docs/00-overview.md)）の実装。

ローカルAIによる全文Semantic検索とMCP経由でのAI連携を中核とするmacOSネイティブアプリ。
ファイルが正本・SQLiteは再構築可能なインデックス、という設計原則に従う。

## 構成

```
Package.swift             # SwiftPM（Swift 6.2 / macOS 14+）
Sources/
  PaperdCore/             # 共有ロジック（アプリとMCPがリンク → docs/01）
    Database/             #   GRDBスキーマv1・マイグレーション（→ docs/02）
    Library/              #   ライブラリレイアウト・meta.json・再構築（→ docs/03）
    Bibtex/               #   bibtex動的生成・citation key（→ docs/02 2節）
    Metadata/             #   arXiv / Crossref / S2 / OpenAlex クライアントと解決順序（→ docs/04 3節）
    Chunking/             #   DoclingDocumentパース・セクション尊重チャンキング（→ docs/06 2節）
    Search/               #   FTS5 + ベクトルKNN + RRFハイブリッド検索（→ docs/06 4節）
    Jobs/                 #   jobsキュー・指数バックオフ（→ docs/04 7節）
    Ingest/               #   6ステージ取り込みパイプライン・JobRunner actor（→ docs/04）
    Worker/               #   PythonワーカーHTTPクライアント・worker.lock（→ docs/05, 01 3節）
  PaperdMCPKit/           # MCPサーバロジック（stdio JSON-RPC自前実装 + 5ツール → docs/07）
  PaperdMCP/              # paperd-mcp CLI
  Paperd/                 # SwiftUIアプリ（最小UI: 3ペイン・リスト・BibTeXコピー・FTS検索）
Tests/PaperdTests/        # Swiftテスト（Swift Testing、97件）
worker/                   # Pythonワーカー（FastAPI / Docling / bge-m3 → docs/05）
docs/                     # 設計書
```

## ビルドとテスト

### Swift（PaperdCore / MCP / アプリ）

```sh
swift build               # 全ターゲット
swift test                # テスト一式（Swift Testing）
scripts/make-app.sh --open  # アプリの起動（推奨: .appバンドル生成 + 起動）
swift run Paperd          # 直接起動も可（非バンドル実行のため一部のOS統合が不完全）
```

> **アプリの動作確認は `scripts/make-app.sh --open` を推奨**。`swift run` はバンドルなしの
> 素のプロセスとして起動するため、macOSのアプリ統合が不完全になる（キーボードフォーカスが
> 取れない・URLスキーム未登録・Dock表示なし等）。フォーカス問題はコード側でも回避済みだが、
> バンドル実行なら `paperd://` スキームやMCPスニペットの実パス（Contents/Helpers/paperd-mcp）
> も含めて設計書どおりの構成で確認できる。

要Xcode（Swift Testingを使うため。Command Line Toolsのみでは `swift test` 不可）。

### Pythonワーカー

```sh
cd worker
uv sync                   # 開発用（軽量。FastAPI + pytest のみ）
uv run pytest             # テスト（18件）
uv sync --extra ml        # 実運用（Docling + sentence-transformers。2〜3GB）
uv run paperd-worker --token SECRET --port 0   # 起動（{"port": N} を標準出力に通知）
```

### MCPサーバ

```sh
swift build
echo '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}' | .build/debug/paperd-mcp
```

環境変数:

| 変数 | 意味 |
|---|---|
| `PAPERD_LIBRARY` | ライブラリの場所（既定 `~/PaperdLibrary`） |
| `PAPERD_WORKER_DIR` | `worker/` の場所（semantic検索用ワーカーのオンデマンド起動） |
| `PAPERD_MAILTO` | Crossref / OpenAlex politeプール用メールアドレス |
| `PAPERD_S2_API_KEY` | Semantic Scholar APIキー（任意） |

Claude Code への登録例（`.mcp.json`）:

```json
{
  "mcpServers": {
    "paperd": {
      "type": "stdio",
      "command": "/path/to/paperd_test/.build/debug/paperd-mcp",
      "env": {"PAPERD_WORKER_DIR": "/path/to/paperd_test/worker"}
    }
  }
}
```

## 実装状況（→ docs/10 のマイルストーン）

| | 範囲 | 状態 |
|---|---|---|
| M1 基盤 | スキーマv1 / meta.json入出力 / インデックス再構築 / 最小UI | ✅ |
| M2 取り込み | メタデータ解決4ソース / jobsキュー / 6ステージパイプライン / 重複検出（DOI・arXiv・pdf_hash） / ローカルPDF解決（convert先行 + Crossref bibliographic検索） / JobRunner | ✅ |
| M3 AI処理 | ワーカーHTTP API / Docling・bge-m3エンジン（遅延ロード） / チャンキング | ✅ |
| M4 検索 | ハイブリッド検索（FTS5 + KNN + RRF） / 検索UI（ワーカー起動時はsemantic併用） / PDFビューア | ✅ |
| M5 MCP | paperd-mcp 6ツール（search / bibtex / fulltext / metadata / add_paper / **apply_fulltext_patches**） / stdio JSON-RPC | ✅ |
| 変換品質 | 文字化け検知ヒューリスティック（conversion_warningsバッジ） / 高精度再変換（force_ocr + formula_enrichment、reconvertジョブ） / **MCP経由のLLM修正ワークフロー**（paper.corrected.mdオーバーレイ + 履歴 + reindex自動投入 → docs/05 4.1・5節, docs/07 2.6節） | ✅ |
| M6 周辺 | 引用グラフ（refetch_citationsジョブ / stub論文 / TTL / エゴネットワーク表示 / stub昇格） / **Markdownタブ（変換結果の確認 — AIが読む本文の変換ミス検出手段 → docs/09 4節）** / ノートUI / 取り込みUI（＋ダイアログ・PDFドロップ） / ジョブ進捗UI / 設定画面（MCPスニペット・ワーカーセットアップ） / **お気に入り・自著論文フラグ + 自著被引用ネットワーク（リッチ表示 → docs/09 4.1節）** / **ワーカー自動起動 + ステータスバーインジケータ + MCP登録導線・最終アクセス表示（→ docs/07 6節, docs/09 9節）** / **配布準備: ワーカー同梱+自動展開・uv探索（GUIのPATH問題対応）・release.sh（署名/notarization）・インデックス再構築メニュー・終了時ワーカー停止・実プロセスMCPテスト** | ✅ |

### v1の既知の残課題

- 初回セットアップウィザードの磨き込み（現状は設定画面の「ワーカー」タブから手動で `uv sync` / 起動）
- 検索ヒットからのPDFページジャンプ（provenance近似 → docs/09 5節。Markdownタブへのジャンプは実装済み）
- 引用グラフの被引用数によるノードサイズ反映（stub行にcitationCount列がないため）
- 手動解決UIのCrossref候補リスト表示（DOI/arXiv ID直接入力は実装済み）
- コレクションのドラッグ&ドロップ・階層編集（作成/削除/リネーム/所属トグル/フィルタは実装済み）
- 論文リストの絞り込みトークン（年範囲・status・venue）
- JobRunnerのネットワーク系ジョブ並列化（現状は全直列）

### 設計書からの主な乖離（実装上の判断）

1. **sqlite-vec → 純Swift KNN**: システムSQLiteはSQLite拡張をロードできないため、
   `vec_chunks` を通常テーブル（float32 BLOB）とし `VectorStore` がブルートフォースKNNを行う。
   インターフェース（`rowid = chunks.id`）は設計書と同一で、sqlite-vec導入時はこの型のみ差し替え。
2. **MCP SDKは使わず最初からstdio JSON-RPC自前実装**（docs/07 1節が許容する最小構成。
   tools/list と tools/call のみ）。
3. **チャンクのトークン数はbge-m3トークナイザでなく近似**（単語数とchars/4の大きい方）。
4. **JobRunnerのジョブ実行はv1では全直列**（設計書はネットワーク系2〜3並列。並列化は今後）。
5. **コレクション機能は実装後に廃止**（2026-06、docs/02の設計変更メモ）。お気に入り・自著論文フラグに置換。
   既存のコレクションデータ（テーブル・collections.json）はマイグレーションv3で破棄される。
6. **Supplementary PDFの交絡バグ（E2Eで発見・修正済み）**: 自分のDOIを持たない短い文書では
   参考文献がID抽出窓（冒頭6000字）に入り、引用先のDOIで別論文として誤登録された。
   ID抽出をReferences見出しより前に限定して修正（→ docs/04 4節）。
7. **URL取り込みがID入りURL以外で失敗（E2Eで発見・修正済み）**: `.webpage`/`.directPDFURL` が
   resolverのデッドエンドだった。citation_*メタタグ解決・直接PDFダウンロードを実装（→ docs/04 2節）。
   あわせて、resolveが追記したpdf_urlを同一run内のfetchが読めない（Jobスナップショットのstale payload）
   バグも修正。NeurIPS 2017のAttention論文URLで indexed まで実証。
8. **MCPサーバが initialize 応答直後にSIGABRT（実クライアント接続で発見・修正済み）**:
   stdioループの `synchronizeFile()`（fsync）がパイプ上で `NSFileHandleOperationException` を投げて即死し、
   tools/list に応答できずツールが1つも登録されなかった。単発パイプのE2E（1リクエスト→1応答）では
   応答後のクラッシュが見えず長期間潜伏。fflushのみに修正し、複数リクエストのセッションで回帰検証。
9. **get_fulltext(section指定)が修正適用直後に旧本文を返す（実AI利用で発見・修正済み）**:
   section経路はチャンク（reindexジョブ待ち）由来のため、apply_fulltext_patches直後やアプリ非起動時に
   未修正テキストが返っていた。修正版がある論文は有効Markdownからの見出し抽出に切替（→ docs/07 2.3節）。
10. **重複reindexジョブで負荷事故（実AI利用で発見・修正済み）**: MCPの修正パッチを5バッチに
   分けて適用 → reindexが5本積まれ、同一論文のembedding再計算が並行実行されてマシン全体が
   重くなった。同一kind+論文のqueued/running中は投入しない重複排除を導入（→ docs/04 7節）。
11. **ハブ論文の引用グラフでフリーズ（E2Eで発見・修正済み）**: 次数1,600超の古典論文で
   表示ノードが爆発（2ホップで最大8万ノード）し、O(n²)レイアウトのUIスレッド同期実行で
   フリーズした。表示上限（1ホップ150・全体400 + 「+N件省略」表示）と漸進レイアウトで修正（→ docs/08 6節）。

### 動作確認済みのE2E経路（実環境・実APIで検証済み）

実PDF（J. Appl. Phys. 2023の10ページ論文）+ 実ワーカー（Docling + bge-m3）+ 実API（Crossref / S2 / OpenAlex）で以下を確認:

- **PDFドロップ → indexed**: ローカルPDF解決（Docling変換 → タイトル抽出 → Crossref bibliographic検索でDOI確定 → S2/OpenAlex補完）→ 35チャンクのembedding・インデックス化
- **引用グラフ**: 取り込み完了時のrefetch_citations自動投入 → S2 + **OpenAlex補完マージ**（→ docs/08 1節）。実論文でS2の索引漏れ（被引用4/9件）をOpenAlexが補完して実勢9件に、出版社非公開だった参考文献46件もreferenced_worksから取得できることを確認
- **検索**: 英語ハイブリッド（FTS5+semantic）および**日本語クエリ→英語論文の言語横断semantic検索**
- **MCP**: `paperd-mcp` 経由の `search_papers`（日本語semantic）/ `get_bibtex`（完全な@articleエントリ）
- **変換修正ワークフロー**: 実論文の文字化け（= が ¼ に化けた66箇所を検知）に対し、MCP `apply_fulltext_patches` でパッチ適用 → `paper.corrected.md` 作成（原本不変・履歴記録）→ reindexジョブ自動投入 → 修正後テキストがFTS検索にヒット・`conversion_warnings` バッジ更新まで一気通貫で確認
- **高精度再変換（実Vision OCR）**: 同論文の ¼ 化け66箇所が `force_ocr`（ocrmac）で**全件回復**（x ¼ 0 : 52 → x = 0.52）。副作用のキリル同形字（PbTiO3→РЬТіОз等19字）は品質検知が捕捉し、MCP修正で仕上げ可能
- `paperd-cli`（jobs / papers / add / attach / resolve / reconvert / markdown / delete / retry-failed / process / search）でヘッドレス運用可能

### E2Eで発見・修正した不具合

1. ワーカー `/embed` が `async def` でブロッキング実行 → bge-m3初回ロード中（約3分）に全エンドポイント停止、`/convert` の202応答までタイムアウト。`anyio.to_thread` で修正 + 回帰テスト
2. Swift側URLSessionの既定60秒タイムアウト → モデルのコールドロードに足りず600秒へ延長
3. ワーカー再起動時のlockファイル競合（旧プロセスの遅延シャットダウンが新プロセスのlockを削除）→ pid所有者チェック付きunlinkに修正
4. Doclingが論文タイトルを `title` でなく `section_header` として出力するケース → 見出しフォールバック付きタイトル抽出（`DoclingParser.titleCandidate`）
5. S2の `"data": null`（出版社がreferences非公開の論文）をパースエラー扱い → 空リストとして処理
6. PDFドロップ時、誌名ランニングヘッダをタイトルと誤認 → 無関係なエントリとして登録され、URL登録済みの同一論文（metadata_only）と紐づかない問題 → 解決チェーンを再設計（本文刷り込みDOI/arXiv IDの抽出を最優先・全大文字ヘッダの優先度低下・解決結果のタイトル検証・metadata_only行への自動合流・PDFタブのドロップによる明示添付 → docs/04 4節）
7. ローカルPDFのCrossref書誌検索が**SSRNプレプリント版を出版版（Acta Materialia）より上位に返し**、@misc・abstract欠落・S2引用取得404・引用グラフstub行との二重登録が連鎖発生 → 僅差の出版版（journal-article / proceedings-article）を優先するレコード選択 + 解決後DOI重複時のstub吸収マージを実装（→ docs/04 4節）
