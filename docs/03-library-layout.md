# 03. ライブラリレイアウト

## 1. 設計原則

1. **ファイルが正本（source of truth）、SQLiteは再構築可能なキャッシュ**
   - `meta.json` + PDF + Markdown から `library.sqlite` を完全に再構築できる
   - 「インデックス再構築」をアプリのメニュー機能として仕様化する（→ 5節）
2. **すべてのキーはUUID**。パスや連番に意味を持たせない
3. **ライブラリディレクトリはポータブル**。丸ごとコピー/移動/同期しても整合する
4. マシン固有のもの（Python環境・モデル・ログ）はライブラリに入れない

## 2. ディレクトリ構造

```
~/PaperdLibrary/                      # ユーザ可視。場所は設定で変更可能
  library.json                        # ライブラリ識別子・フォーマットバージョン
  papers/
    {uuid}/
      paper.pdf                       # オリジナルPDF
      paper.md                        # AIフレンドリー形式（Docling出力Markdown。不変）
      paper.docling.json              # Docling構造化ドキュメント（チャンク再生成用）
      paper.corrected.md              # ユーザ/LLMによる修正版Markdown（存在する場合これが有効Markdown → 05 5.2節）
      paper.corrections.json          # 修正履歴（日時・パッチ・注記）
      meta.json                       # メタデータの正本
      notes.md                        # ユーザノート（存在しない場合あり）
      supplements/                    # 補助ファイル（Supplementary等。複数可・任意種別・存在しない場合あり）
  index/                              # 再構築可能領域（同期対象外）
    library.sqlite                    # DB + FTS5 + ベクトルインデックス
    library.sqlite-wal / -shm

~/Library/Application Support/paperd/ # マシンローカル（同期しない）
  worker/                             # 展開済みワーカーソース + .venv
  models/                             # embeddingモデルキャッシュ
  worker.lock                         # ワーカー多重起動防止
  logs/
```

## 3. ファイルスキーマ

### library.json

```json
{
  "formatVersion": 1,
  "libraryId": "8f14e45f-...",
  "createdAt": "2026-06-11T10:00:00Z"
}
```

### meta.json（papers/{uuid}/）

`papers` 行 + 著者 + 所属コレクションIDのシリアライズ。例:

```json
{
  "formatVersion": 1,
  "id": "8f14e45f-...",
  "title": "Attention Is All You Need",
  "abstract": "...",
  "year": 2017,
  "authors": [
    {"displayName": "Ashish Vaswani", "s2AuthorId": "1738948", "orcid": null}
  ],
  "venue": "NeurIPS",
  "bibtexType": "inproceedings",
  "booktitle": "Advances in Neural Information Processing Systems",
  "journal": null,
  "volume": null, "number": null, "pages": null, "publisher": null,
  "doi": "10.5555/3295222.3295349",
  "arxivId": "1706.03762", "arxivVersion": "v5",
  "s2PaperId": "204e3073...", "openalexId": "W2741809807",
  "url": "https://arxiv.org/abs/1706.03762",
  "bibtexCached": null,
  "citationKeyOverride": null,
  "isFavorite": false,
  "isOwn": false,
  "pdfHash": "sha256:...",
  "status": "indexed",
  "addedAt": "2026-06-11T10:00:00Z",
  "updatedAt": "2026-06-11T10:05:00Z"
}
```

- `supplements/` は**フォルダの中身そのものが正本**（meta.json・DBには登録しない。
  一覧はディレクトリ走査で得る。論文削除でフォルダごとゴミ箱へ移動され、再構築の影響を受けない）
- DB行の更新時、`PaperdCore` が同一トランザクション境界で `meta.json` を書き出す（ファイル書き込み→DB更新の順。クラッシュ時はファイルが新しい状態になり、再構築で回復）
- `citations`・`chunks`・embedding は `meta.json` に**含めない**（前者はAPIから、後者は `paper.docling.json` から再生成可能）

## 4. 同期を見据えた設計（v2準備）

v1は単一Macローカル完結だが、以下を満たすことで将来 iCloud Drive / Dropbox 等での同期に対応可能にする。

- `index/` は同期対象外とする（iCloud Drive では `index.nosync` へのリネームで除外、という運用をドキュメント化）
- embeddingベクトルは同期しない。各マシンが `paper.docling.json` からローカルで再生成する（モデル差異・サイズの問題を回避）
- `meta.json` の競合: v1では検出のみ考慮（同期ツールが生成する競合コピー `meta (conflicted copy).json` を起動時スキャンで検出し警告）。マージはv2課題
- 論文の追加・削除はディレクトリ単位なので同期と相性が良い（部分書き込み対策として、取り込み完了まで `papers/{uuid}.partial/` に書き、完了時にリネーム）

## 5. インデックス再構築

メニュー「ライブラリ > インデックスを再構築」で以下を実行:

1. `index/library.sqlite` を退避（`.bak`）し新規作成
2. `papers/*/meta.json` を全走査して `papers` / `authors`（お気に入り・自著フラグ含む）を再投入
3. 各論文の `paper.docling.json` からチャンクを再生成し、FTS5投入 + embedding再計算（ワーカー使用、進捗表示）。**`paper.corrected.md` がある論文はそちらを優先**してMarkdownからチャンク生成する（→ [05](05-pdf-conversion.md) 5.2節）。`conversion_warnings` は `paper.md` から再計算する
4. `citations` はAPIから遅延再取得（再構築直後はグラフが空でもよい）

部分再構築（単一論文の再インデックス）も同じ経路で実装する。embedding再計算はモデル変更時にも使う（`embedding_meta` と現行設定の不一致で検出 → [06](06-search-rag.md)）。

## 6. 削除・ゴミ箱

- 論文削除はディレクトリごと `~/.Trash` へ移動（Finderのゴミ箱と統合、誤削除から回復可能）
- DB行は `ON DELETE CASCADE` で chunks / citations / notes 索引も削除
- `jobs` の該当行は削除前に取り除く（`jobs.paper_id` はCASCADEなしの参照のため。
  キューの履歴は論文と独立して保持する価値がないと判断）
- 削除後、**どの引用エッジからも参照されなくなったstub行を掃除**する
  （stubは引用グラフ表示のためのキャッシュであり、エッジを失えば存在意義がない → [08](08-citation-graph.md)）
