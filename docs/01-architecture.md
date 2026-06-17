# 01. アーキテクチャ

## 1. 全体構成: 3プロセス + 共有ライブラリ

```mermaid
graph TB
  subgraph App["paperd.app (Swift/SwiftUI)"]
    UI[SwiftUI UI<br/>ライブラリ / PDFKitビューア / 引用グラフ]
    JR[JobRunner actor<br/>取り込みパイプライン]
    Core1[PaperdCore]
  end

  subgraph MCP["paperd-mcp (Swift CLI, stdio)"]
    Tools[search / bibtex / fulltext / metadata / add_paper]
    Core2[PaperdCore]
  end

  subgraph Worker["paperd-worker (Python)"]
    DOC[Docling<br/>PDF → Markdown/JSON]
    EMB[bge-m3<br/>embedding生成]
  end

  subgraph Lib["~/PaperdLibrary"]
    FS[papers/uuid/<br/>paper.pdf · paper.md · meta.json]
    DB[(index/library.sqlite<br/>WAL · FTS5 · vec_chunks · jobs)]
  end

  EXT[arXiv / Crossref / Semantic Scholar / OpenAlex]
  Claude[MCPクライアント<br/>Claude等]

  Claude -->|stdio JSON-RPC| Tools
  UI --> Core1
  Core1 --> DB
  Core1 --> FS
  JR -->|HTTP 127.0.0.1 + token| DOC
  JR -->|HTTP| EMB
  JR -->|REST| EXT
  Core2 -->|読取 + jobs INSERT| DB
  Core2 -.->|オンデマンド起動| EMB
  JR -->|jobsポーリング| DB
```

| コンポーネント | 役割 | 技術 |
|---|---|---|
| `paperd.app` | UI、PDFビューア、ジョブオーケストレーション、DB書き込みの主体 | Swift / SwiftUI |
| `paperd-worker` | PDF→Markdown変換、embedding生成 | Python（venv + pip）。アプリ/MCPが子プロセスとして起動 |
| `paperd-mcp` | MCPクライアントへのツール提供 | Swift CLI（stdio）。アプリバンドル内 `Contents/Helpers/` に同梱 |
| `PaperdCore` | DB アクセス、検索、bibtex生成、メタデータ解決、ワーカー起動の共有ロジック | SwiftPMローカルパッケージ。アプリとMCPの双方がリンク |

### 設計原則

1. **ファイルが正本、SQLiteは再構築可能なインデックス**（→ [03](03-library-layout.md)）
2. **重い処理（変換・embedding）はPythonワーカーに集約**し、Swift側はオーケストレーションに徹する
3. **プロセス間の書き込み競合は `jobs` キューで構造的に回避**する（→ 5節、[04](04-ingest-pipeline.md)）
4. ロジックの二重実装を避けるため、アプリとMCPは `PaperdCore` を共有する

## 2. リポジトリ構成（実装時）

```
paperd/
  Paperd/                 # macOSアプリ (SwiftUI)
  PaperdCore/             # 共有SwiftPMパッケージ
    Sources/PaperdCore/
      Database/           # GRDB.swift, マイグレーション
      Search/             # ハイブリッド検索, RRF
      Bibtex/             # bibtex生成
      Metadata/           # arXiv/Crossref/S2/OpenAlexクライアント
      Worker/             # Pythonワーカーのライフサイクル管理・HTTPクライアント
      Library/            # ファイルレイアウト, meta.json入出力
  PaperdMCP/              # MCPサーバCLI
  worker/                 # Pythonワーカー (pyproject.toml + src/)
  docs/                   # 本設計書
```

## 3. Pythonワーカー

### 3.1 IPC: localhost HTTP + 認証トークン

- ワーカーは起動時に **127.0.0.1 のランダムポート** で FastAPI サーバを立てる
- 起動引数で渡される**ワンタイムシークレットトークン**を全リクエストの `Authorization` ヘッダで検証
- ポート番号はワーカーが標準出力に1行JSON（`{"port": 51234}`）で通知し、親プロセスが読み取る

stdio JSON-RPCではなくHTTPを選ぶ理由: (a) 長時間ジョブの進捗通知（ポーリング/SSE）、(b) 複数リクエストの並行処理、(c) `curl` で叩けるデバッグ容易性。

APIエンドポイント仕様は [05-pdf-conversion.md](05-pdf-conversion.md) と [06-search-rag.md](06-search-rag.md) を参照。

### 3.2 ライフサイクル

- **アプリから**: **アプリ起動時に自動起動**（設定「アプリ起動時にワーカーを自動起動」、既定ON）し、以後常駐。**アプリ終了時に停止する**（残留ワーカーによるメモリ占有の防止。MCPは必要時にオンデマンドで再起動できる）。ワーカーはユーザが意識しないインフラとして扱い、状態はステータスバーのインジケータで可視化する（→ [09](09-ui.md) 9節）
- **MCPから**: semantic検索のクエリembedding生成時にオンデマンド起動。**アイドルタイムアウト（既定10分）で自動終了**する常駐モード
- 多重起動の防止: `~/Library/Application Support/paperd/worker.lock`（PID + ポート + トークンのファイルロック）。既存ワーカーが生きていれば再利用する。**再利用時は `/health` のバージョンを照合し、期待バージョンと不一致なら旧プロセスを終了して起動し直す**（コード更新後に旧ワーカーが残留し、新しいオプションが黙って無視される事故の防止）

### 3.3 Python環境のセットアップ（venv方式）

**配布バンドルでのワーカー配置**: 配布された `.app` は `Contents/Resources/worker/` に
ワーカーのソース（`pyproject.toml` + `src/`）を同梱する。初回起動時にアプリが
`~/Library/Application Support/paperd/worker/` へ展開して `workerDir` の既定値とし、
バージョンが上がったら（pyproject.toml の version 比較）ソースを上書き更新する（`.venv` は
温存し、再構築時は `pip install -e` の冪等性に任せて差分適用する）。開発ビルドではリポジトリ内
`worker/` を直接使う（→ docs/09 9節）。

**Python の探索（`PythonLocator`）**: GUI アプリの PATH には Homebrew 等が含まれないため、
Python 3.11+ のバイナリを既知の場所（`/opt/homebrew/bin/python3.13` `python@3.13/bin/...` /
`/usr/local/bin/...` / `~/.pyenv/shims/...`）から新しいバージョン順に探索し、見つかった候補は
`python -c "import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)"` で要件を検証してから返す。
未検出の場合は設定画面でインストール方法（`brew install python@3.11` 等）を案内する。
macOS 標準同梱の `/usr/bin/python3` は通常 3.9 系のため候補に含めるが検証で除外される。

**workerDir の解決（`WorkerLocator.resolve()`）**: 任意ディレクトリ指定 UI や環境変数は持たず、
解決順は固定: ①バンドル/バイナリの親方向に `worker/pyproject.toml` があれば dev candidate を採用、
②配布バンドルの `Contents/Resources/worker` を `deployIfNeeded()` で Application Support に展開、
③既存の Application Support 展開ディレクトリ。同じ関数を Paperd アプリ・paperd-mcp・paperd-cli
の 3 バイナリ全てから呼ぶため、起動経路によらず workerDir が一意に決まる。

Docling + PyTorch で環境サイズが 2〜3GB になるため、アプリバンドルへの同梱はしない。

1. 設定画面「環境構築（venv + pip install）」ボタンで、`<workerDir>/.venv` を `python -m venv` で作成し、`.venv/bin/pip install --upgrade -e .[ml]` で Docling / sentence-transformers / PyTorch を同期する
2. ワーカーは `<workerDir>/.venv/bin/python -m paperd_worker --token ... --port 0 ...` で起動する（`paperd_worker/__main__.py` がエントリ）
3. embedding モデル（bge-m3）は初回利用時に `models/` へダウンロード
4. ウィザードは進捗表示・中断再開・オフライン時の明示的エラーを備える（→ [09](09-ui.md)）
5. ワーカーのコード（`worker/`）はアプリバンドル内 `Contents/Resources/worker/` に同梱し、環境のみ外部構築

**設計変更ノート（2026-06-17）**: 当初は `uv` 一本（`uv sync` / `uv run paperd-worker`）で
セットアップと起動を行っていたが、`uv` は brew / cargo / pipx / 公式インストーラ等のヘビーユーザに
よる管理経路が多く、配布側が `depends_on formula: "uv"` で重ねると PATH 優先順位事故を起こしやすい
ことから、macOS 標準同梱の `python3 -m venv` + `pip install` に切り替えた（Issue #6）。これに伴い
設定画面のボタン実装も `UVLocator` 経由から `PythonLocator` の絶対パスを `Process.executableURL`
に渡す形に統一し、Issue #3（GUI アプリの素 `uv` 解決失敗）も併せて解消した。

同日: 設定画面の workerDir パス選択 UI（TextField + 選択ボタン）と `PAPERD_WORKER_DIR` 環境変数を
撤廃。venv 方式では workerDir の有効値が「リポジトリ内 worker/（開発）」または
「Application Support/paperd/worker/（配布）」の二択しか存在しないため、任意ディレクトリを
ユーザに選ばせる UI は誤誘導（実際 Downloads などを指定すると `pip install -e .` が
`pyproject.toml` を見つけられず失敗した）。`WorkerLocator.resolve()` で一意に解決し、設定画面では
解決済みパスを read-only で表示するだけにした。

## 4. MCPサーバ

- **トランスポート**: stdio のみ（MCPクライアントが子プロセスとして起動）
- **配置**: `paperd.app/Contents/Helpers/paperd-mcp`。アプリが起動していなくても単独で動作する
- **SDK**: Swift MCP SDK を**薄いアダプタ層でラップ**し、SDK差し替え（公式 ↔ コミュニティフォーク ↔ 自前stdio実装）を可能にする。MCP仕様のうち tools のみ使用し、依存面積を最小化する
- アプリ内に「MCP設定スニペットをコピー」するUIを設け、`claude_desktop_config.json` 等への登録を補助する

ツール定義・書き込み設計は [07-mcp-server.md](07-mcp-server.md) を参照。

## 5. SQLite の多プロセス共有

- **WALモード** + `busy_timeout = 5000ms` で運用。複数プロセスからの並行読み取り + 短時間の書き込みは安全に成立する
- 書き込みの原則:
  - **アプリ（JobRunner）が長時間処理を伴う書き込みの唯一の主体**
  - MCPサーバの書き込みは「`jobs` テーブルへの短いINSERT」と「メタデータ解決結果の `papers` 行INSERT」に限定
- アプリへのジョブ通知: MCPがジョブ投入後に `DistributedNotificationCenter` で通知（補助）。主たる駆動はアプリ側JobRunnerの定期ポーリング（既定5秒間隔、アイドル時は間隔を延長）
- スキーマ詳細は [02-data-model.md](02-data-model.md)

## 6. URLスキーム

アプリは `paperd://` カスタムURLスキームを登録する（`CFBundleURLTypes`）。

| URL | 動作 |
|---|---|
| `paperd://import?url=<encoded-url>` | URLを取り込みパイプラインへ投入（外部連携の汎用入口。v2のブラウザ取り込み案 → [11](11-browser-capture.md) でも利用） |
| `paperd://import?arxiv=<id>` / `?doi=<doi>` | ID指定の取り込み |
| `paperd://paper/<uuid>` | 該当論文を開く（検索結果からのディープリンク用） |

## 7. 配布形態

### リリース手順（scripts/release.sh）

1. `CODESIGN_IDENTITY="Developer ID Application: ..."` を設定（Apple Developer Programの証明書）
2. `xcrun notarytool store-credentials <profile>` でnotarization認証を登録し `NOTARY_PROFILE` に設定
3. `scripts/release.sh` を実行 → Releaseビルド → Hardened Runtime署名（ヘルパー→アプリの順、
   `--deep` は使わない）→ notarization → staple → zip生成
- ワーカーのPython仮想環境（`.venv`）は.appに含まれず、ユーザ領域で `venv + pip install -e` により構築されるため、署名対象はSwiftバイナリと同梱ワーカーソースのみ
- 環境変数未設定時はad-hoc署名で動作確認用ビルドになる

### Homebrew配布（自前tap）

主たる配布チャネルはHomebrew cask（`brew install --cask paperd-app/paperd/paperd`）。
caskはPython環境管理ツールへの依存を宣言しない。Python 3.11+ が見つからない場合は
アプリの設定画面でインストール方法を案内し、ワーカー環境は `venv + pip install -e` で構築する。
GitHub Releasesのzipを併記の直接DLとして案内する。

1. GitHubに `homebrew-paperd` リポジトリ（tap）を作る
2. `scripts/release.sh`（既定リポジトリ: paperd-app/paperd） が `dist/Casks/paperd.rb`
   （version / sha256 / URL埋め込み済み）を生成するので、tapの `Casks/` へコピーしてpush
3. zipはGitHub Releasesに `v{version}` タグでアップロード
4. 知名度がついたら homebrew/cask 本体への収載を検討（それまでは自前tap）

### ライセンス

**FSL-1.1-Apache-2.0**（Functional Source License）。ソース公開・個人/研究利用は自由・
競合する商用再配布のみ禁止・各リリースは公開2年後にApache 2.0へ自動転換（→ LICENSE.md）。
依存ライブラリ（GRDB / Docling / bge-m3 / ocrmac等）はすべてMITで商用利用可。

### ローカリゼーション

UI文言は ja / en の2言語（システム言語追従、ベース言語ja → [09](09-ui.md) 10節）。
Core / MCP / CLI / スキルの文字列は英語固定。ビルドへの影響:

- `Package.swift`: Paperd ターゲットに `defaultLocalization: "ja"` と `Localizable.xcstrings` リソースを宣言
- `scripts/make-app.sh`: `xcrun xcstringstool compile` で xcstrings を `en.lproj/Localizable.strings` に
  コンパイルして `Contents/Resources/` へ置き、Info.plist に
  `CFBundleDevelopmentRegion` / `CFBundleLocalizations` を書き込む

- **Developer ID 署名 + notarization による直接配布**（dmg / Sparkleによる自動更新を想定）
- Mac App Store は対象外: Pythonサイドカーの実行・外部プロセス起動が App Sandbox と非互換のため
- アプリ本体・`paperd-mcp`・同梱ワーカーソースは署名対象。Pythonワーカー環境（`.venv`）は実行時構築のためユーザ領域に置き、署名対象外（Gatekeeperの制約を受けない）

## 8. 主要な外部依存

| 依存 | 用途 | ライセンス |
|---|---|---|
| GRDB.swift | SQLiteアクセス | MIT |
| sqlite-vec | （v1未使用）将来のベクトル検索候補。システムSQLiteが拡張をロードできないため、v1はSwift側ブルートフォースKNNで代替（→ [06](06-search-rag.md) 3節） | MIT/Apache-2.0 |
| Docling | PDF→Markdown/JSON変換 | MIT |
| sentence-transformers + bge-m3 | embedding生成 | Apache-2.0 / MIT |
| FastAPI + uvicorn | ワーカーHTTPサーバ | MIT |
| Swift MCP SDK | MCPサーバ実装（薄くラップ） | MIT |
