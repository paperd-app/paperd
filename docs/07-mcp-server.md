# 07. MCPサーバ

## 1. 位置づけ

`paperd-mcp` は stdio で動作する Swift 製 CLI。アプリバンドル内 `Contents/Helpers/paperd-mcp` に同梱され、MCPクライアント（Claude Desktop / Claude Code 等）が子プロセスとして起動する。**paperd.app が起動していなくても単独で動作する**。

- DBアクセス・検索・bibtex生成・メタデータ解決は `PaperdCore` をアプリと共有する（→ [01](01-architecture.md)）。ロジックの二重実装はしない
- MCP SDK は**薄いアダプタ層でラップ**する。公式 Swift SDK の停滞リスクに対するヘッジで、公式 ↔ コミュニティフォーク ↔ 自前実装を差し替え可能にする。MCP仕様のうち tools のみ使用するため、最悪でも stdio JSON-RPC の自前実装で代替できる（tools/list と tools/call のみ）

## 2. v1 ツール定義（6つ）

### 2.1 search_papers — ハイブリッド検索

ライブラリ全文に対するハイブリッド検索（FTS5 + semantic、RRF統合 → [06](06-search-rag.md)）。

```json
{
  "name": "search_papers",
  "description": "ユーザの論文ライブラリを自然言語またはキーワードで全文検索する。本文チャンク単位でヒットし、該当箇所のスニペットを返す。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "query":      {"type": "string", "description": "検索クエリ（自然言語可）"},
      "top_k":      {"type": "integer", "default": 10, "maximum": 50}
    },
    "required": ["query"]
  }
}
```

出力例:

```json
{
  "results": [
    {
      "paper_id": "8f14e45f-...",
      "title": "Attention Is All You Need",
      "authors": ["Ashish Vaswani", "Noam Shazeer"],
      "year": 2017,
      "score": 0.87,
      "section_path": "3. Method > 3.2 Attention",
      "snippet": "Scaled dot-product attention computes ..."
    }
  ]
}
```

### 2.2 get_bibtex — bibtex取得

```json
{
  "name": "get_bibtex",
  "description": "論文のBibTeXエントリを返す。paper_id / doi / arxiv_id のいずれか1つで指定する。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "paper_id": {"type": "string"},
      "doi":      {"type": "string"},
      "arxiv_id": {"type": "string"}
    }
  }
}
```

出力は bibtex 文字列（生成仕様 → [02](02-data-model.md)）:

```bibtex
@inproceedings{vaswani2017attention,
  title     = {Attention Is All You Need},
  ...
}
```

### 2.3 get_fulltext — 全文取得

```json
{
  "name": "get_fulltext",
  "description": "論文の全文Markdown（paper.md）を返す。section を指定するとそのセクションのみ抜粋する。長い論文では全文が文字数上限で切り詰められるため、まず get_paper_metadata でセクション一覧を確認し section 指定での取得を推奨。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "paper_id": {"type": "string"},
      "section":  {"type": "string", "description": "セクション見出しまたはsection_path（任意）"}
    },
    "required": ["paper_id"]
  }
}
```

- 全文が**上限（既定 50,000 文字）**を超える場合は冒頭から切り詰め、末尾に `[truncated: N chars total. Use the 'section' parameter to fetch specific sections: 1. Introduction, 2. Related Work, ...]` を付与してセクション指定を案内する
- `section` は `chunks.section_path` との前方一致で解決する

- **section指定の出典**: 通常は検索チャンク（`chunks.section_path` 前方一致）から返す。
  ただし**修正のインデックス反映待ち（reindexジョブがqueued/running）の間**は、チャンクが旧本文のままで
  AIが未修正テキストを黙って読んでしまうため（実利用で発見）:
  1. 有効Markdownからの**見出し抽出**で返す（注記付き。Doclingのフラット見出しでは下位小節が
     欠ける可能性があるため、欠落時は全文取得を促す）
  2. 抽出できない場合は旧チャンクを返すが、**未反映の修正がある旨の警告を必ず先頭に付ける**
  反映完了後は従来どおりチャンク（修正済み・完全な構造）から返る

### 2.4 get_paper_metadata — メタデータ取得

```json
{
  "name": "get_paper_metadata",
  "description": "論文の書誌メタデータ（タイトル・著者・年・DOI・ステータス・セクション一覧等）をJSONで返す。",
  "inputSchema": {
    "type": "object",
    "properties": {"paper_id": {"type": "string"}},
    "required": ["paper_id"]
  }
}
```

出力は `meta.json`（→ [03](03-library-layout.md)）相当のJSONに以下を加えたもの:

- `sections`: section_path一覧
- `supplements`: 補助ファイル（Supplementary等）の絶対パス一覧（→ [03](03-library-layout.md)。存在する場合のみ）
- `pdf_path` / `markdown_path`: ローカルファイルの絶対パス（変換修正ワークフローでAIエージェントが
  PDF原文と照合するために使う。Claude Code等のファイルアクセス可能なクライアント向け）
- `conversion_warnings`: 変換品質検知の警告数（→ [05](05-pdf-conversion.md) 4.1節）
- `has_corrections`: `paper.corrected.md` の有無

### 2.5 add_paper — 論文追加（書き込み系）

```json
{
  "name": "add_paper",
  "description": "arXiv ID / DOI / URL からライブラリに論文を追加する。書誌情報は即時返却されるが、PDF取得・変換・検索インデックス化は paperd アプリが非同期で実行する。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "arxiv_id": {"type": "string"},
      "doi":      {"type": "string"},
      "url":      {"type": "string"}
    }
  }
}
```

動作シーケンス:

1. **メタデータ解決を同期実行**（arXiv / Crossref / S2 / OpenAlex → [04](04-ingest-pipeline.md)）し、確定した書誌をレスポンスで即時返却する
2. `papers` 行を INSERT（`status = 'metadata_only'`）し、`jobs` へ `kind = 'ingest'`, `origin = 'mcp'` で INSERT
3. `DistributedNotificationCenter` でアプリへジョブ投入を通知（補助。主駆動はアプリのポーリング → [01](01-architecture.md)）
4. アプリ非起動時はジョブが `queued` のまま残留し、次回アプリ起動時に処理される

出力例:

```json
{
  "paper_id": "a1b2c3d4-...",
  "title": "Attention Is All You Need",
  "year": 2017,
  "status": "metadata_only",
  "message": "書誌情報を登録しました。PDF取得と全文インデックス化は paperd アプリがバックグラウンドで実行します。アプリが起動していない場合は次回起動時に処理されます。"
}
```

### 2.6 apply_fulltext_patches — 変換ミスの修正（書き込み系）

PDF→Markdown変換の意味的な誤り（上付き文字の潰れ・グリフ誤対応等 → [05](05-pdf-conversion.md) 5.2節）を、
ユーザがAIエージェントに修正させるためのツール。**修正はPDF原文に接地させる前提**で、
エージェントは `get_paper_metadata` の `pdf_path` からPDFを読み、Markdownと照合した上でパッチを提出する。

```json
{
  "name": "apply_fulltext_patches",
  "description": "論文Markdownの変換ミスをパッチ（find→replace）で修正する。各findは現在の本文に正確に1回出現する必要がある。修正前に必ずPDF原文（get_paper_metadataのpdf_path）と照合し、原文にない内容を書き込まないこと。修正後は検索インデックスが自動で再構築される。",
  "inputSchema": {
    "type": "object",
    "properties": {
      "paper_id": {"type": "string"},
      "patches": {
        "type": "array",
        "items": {
          "type": "object",
          "properties": {
            "find":    {"type": "string", "description": "現在の本文中の誤り箇所（一意に特定できる長さで）"},
            "replace": {"type": "string", "description": "修正後のテキスト"}
          },
          "required": ["find", "replace"]
        }
      },
      "note": {"type": "string", "description": "修正の根拠メモ（履歴に記録、任意）"}
    },
    "required": ["paper_id", "patches"]
  }
}
```

動作と安全設計:

1. 各 `find` が**有効Markdown中に正確に1回**出現することを検証（0回・複数回はエラーで該当パッチを報告。
   部分適用はしない＝全パッチ検証後に一括適用）。全文置換を受け付けないことで、ハルシネーションによる
   広範な書き換えを構造的に防ぐ
2. 適用結果を `paper.corrected.md` に保存（Docling出力 `paper.md` は不変 → [03](03-library-layout.md)）。
   履歴を `paper.corrections.json` に追記
3. `jobs` へ `kind = 'reindex'` をINSERTし、アプリが修正版から再チャンク・再embeddingする
   （読み書き分離の原則どおり、MCPは短い書き込みのみ → 3節）
4. 応答に適用数と「インデックス再構築はアプリが実行する」旨を返す

### 2.7 add_note — ノートへの追記

```json
{ "paper_id": "...", "content": "Markdownテキスト", "heading": "AIメモ（任意）" }
```

- 論文のノート（`notes.md`、正本 → [03](03-library-layout.md)）に**追記**する。既存のノートは保持され、
  追記は `## {heading}（日付）` セクションとして末尾に追加される（AIがユーザのメモを上書きしない）
- 追記後は `reindex` ジョブを投入し、ノートが全文検索の対象になる（→ [06](06-search-rag.md) 2節）
- 用途: 文献調査スキル（5.1節）の調査メモ保存、要約の永続化


## 3. 読み書きの分離

| 操作 | 経路 |
|---|---|
| 読み取り（search / bibtex / fulltext / metadata） | WALモードの同一 `library.sqlite` を直接読む。アプリの書き込みと並行可能。fulltextは有効Markdown（`paper.corrected.md` 優先 → [05](05-pdf-conversion.md) 5.2節）を返す |
| 書き込み（add_paper / apply_fulltext_patches） | `papers` 行 + `jobs` 行への**短いINSERT**と修正ファイルの書き出しのみ。長時間処理（PDF取得・変換・embedding・再インデックス）はすべてアプリ側JobRunnerが実行 |

MCPサーバは取り込みパイプラインを自前で走らせない。これにより、2プロセスが同じ論文を同時処理する競合が構造的に発生しない（→ [01](01-architecture.md) 5節）。

## 4. semantic検索のクエリembedding

semantic検索にはクエリ自体の embedding が必要で、これは Python ワーカーで生成する。

- `PaperdCore` 経由でワーカーを**オンデマンド起動**。`worker.lock` を確認し、アプリ等が起動済みの既存ワーカーがあれば再利用する（→ [01](01-architecture.md) 3.2節）
- MCPが起動したワーカーはアイドルタイムアウト（既定10分）で自動終了する
- **初回呼び出しはワーカー起動 + モデルロードで数十秒かかりうる**。この間 `search_papers` は FTS5 のみで即時応答し、結果に `"semantic": "warming_up"` を付記する（2回目以降はハイブリッド）

## 5. エラー設計

エラーはMCPの `isError: true` レスポンスで返し、メッセージは**ユーザ（AIエージェント）が次の行動を取れる文面**にする。

| 状況 | メッセージ方針 |
|---|---|
| ライブラリ未初期化（`~/PaperdLibrary` 不在） | 「paperd アプリを一度起動してライブラリを初期化してください」 |
| ワーカー未セットアップ（Python環境なし） | semantic検索を諦めFTS5のみで応答 + 「アプリのセットアップウィザードを完了するとSemantic検索が有効になります」 |
| DB busy（`busy_timeout` 5秒超過） | 「ライブラリが他の処理で使用中です。しばらくして再試行してください」（リトライ可能であることを明示） |
| paper_id / doi / arxiv_id が見つからない | 識別子の形式例を添えて返す |
| add_paper のメタデータ解決失敗 | 失敗したソースと理由（ネットワーク / 404）を返す。ジョブは投入しない |

## 6. セットアップUX

アプリの設定画面に以下の導線を設ける。

1. **「Claude Code 登録コマンドをコピー」**: 実パス入りの `claude mcp add --scope user paperd -- <path>` を
   クリップボードへコピーする（最短の登録経路）。**`--scope user` 必須**: 既定のlocalスコープは
   実行したプロジェクト限定の登録になり、全プロジェクト有効なスキル（6.1節）とスコープが揃わない。
   個人の文献ライブラリは全プロジェクトから使えるべきものなのでuserスコープで登録する
2. **「MCP設定スニペットをコピー」**: インストール先の実パスを埋め込んだ設定JSONをコピーする
   （Claude Desktop等のconfigファイル編集用）
3. **最終アクセスの表示**: `paperd-mcp` はツール呼び出しのたびに最終アクセス（日時・ツール名）を
   マシンローカルの記録ファイルへ書き、アプリの設定画面に「MCP最終アクセス: ◯分前（search_papers）」と
   表示する。「ちゃんと接続できているか」を確認する手段（MCPサーバはクライアントが起動する子プロセスで
   あり、アプリ側からon/offや死活の直接確認はできないため、アクセス痕跡の可視化で代替する）

### 6.1 Claudeスキルの同梱と配布

MCP接続後の「何を頼めるか分からない」ハードルを下げるため、**定型ワークフローをClaudeスキルとして同梱**し、
設定画面からワンクリックで `~/.claude/skills/` へインストールできるようにする。

| スキル | 内容 |
|---|---|
| `paperd-research` | DeepResearch風の文献調査。テーマを分解し**ライブラリ内検索とWeb調査を並列実行**、未所持の重要論文を**ユーザ承認のうえ** `add_paper` で取り込み、調査メモを `add_note` で保存する |
| `paperd-fix-conversion` | 変換修正の規約（pdf_pathとMarkdownの照合 → 一意なfindでのパッチ → 根拠の記録）を手順化 |
| `paperd-cite` | 執筆中の原稿の主張に対し、ライブラリから根拠文献を当てて引用文/BibTeXを出す |

- スキルの実体はリポジトリの `skills/` で管理し、アプリバンドルの `Contents/Resources/skills/` に同梱する
- インストールはユーザ領域への書き込みのため**確認ダイアログ（書き込み先の明示）**を経る。
  既存スキルとの差分があれば「更新あり」と表示して上書き確認する
- 補助導線として、設定画面に**サンプルプロンプト集**（コピーボタン付き）を置く（スキル不要の単発依頼の例示）
- スキルはClaude Code前提（Claude Desktop等はMCPの単発ツール呼び出しのみ）

Claude Desktop（`claude_desktop_config.json`）:

```json
{
  "mcpServers": {
    "paperd": {
      "command": "/Applications/paperd.app/Contents/Helpers/paperd-mcp"
    }
  }
}
```

Claude Code（プロジェクトの `.mcp.json`）:

```json
{
  "mcpServers": {
    "paperd": {
      "type": "stdio",
      "command": "/Applications/paperd.app/Contents/Helpers/paperd-mcp"
    }
  }
}
```

引数・環境変数は不要（ライブラリ位置は `~/Library/Application Support/paperd/` の設定から解決）。アプリの再配置でパスが変わった場合はスニペットの再コピーを案内する。
