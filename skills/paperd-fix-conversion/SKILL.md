---
name: paperd-fix-conversion
description: paperdライブラリ論文のPDF→Markdown変換ミス（文字化け・数式崩れ・誤認識）をPDF原文と照合して修正する。「変換ミスを直して」「Markdownの文字化けを修正して」などで使う。
version: 2
---

# paperd 変換修正ワークフロー

paperd MCPの `apply_fulltext_patches` で論文Markdownの変換ミスを安全に修正する。

## 手順

1. `get_paper_metadata` で対象論文の `pdf_path` / `markdown_path` / `conversion_warnings` を取得する。
2. `get_fulltext` でMarkdownを読み、怪しい箇所を列挙する。典型例:
   - 文字化け: `¼` `½`（≈や数式の誤認識）、`(cid:123)`、キリル文字の混入（РЬТіОз ← PbTiO3）
   - 上付き・下付きの欠落: `10^3 Å` → `103 Å`
   - 数式・化学式の崩れ
3. **必ず `pdf_path` のPDF原文を読んで照合する**。原文にない内容を書かない（これが最重要規約）。
4. パッチを作る。各 `find` は**現在の本文に正確に1回だけ出現する長さ**で切り出す
   （短すぎると複数一致でエラーになる。前後の文脈を含めて一意にする）。
5. `apply_fulltext_patches` で適用する。`note` に修正根拠（PDFの該当ページ・箇所）を書く。
6. 適用後の検証は `get_fulltext` で行う（修正は有効Markdownに即時反映され、section指定でも修正版が返る）。
   `search_papers` のスニペットだけは検索インデックス再構築（アプリがバックグラウンド実行）後に反映される。
   修正履歴はアプリ側に残り、ユーザが取り消せる。

## 規約

- PDF原文と照合せずに「ありそうな修正」をしない
- 大量の機械的置換より、意味が壊れている箇所を優先する（conversion_warningsの種類が手がかり）
