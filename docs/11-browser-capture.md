# 11. ブラウザからのワンクリック取り込み（v2設計案）

> **本機能はv1では実装しない**（2026-06決定）。将来の実装に備えた設計案として保持する。位置づけは [10](10-roadmap-risks.md) 2節のv2候補を参照。v1での代替手段は、UIへのURL入力・PDFドロップ（→ [09](09-ui.md) 7節）および `paperd://import` URLスキーム（→ [01](01-architecture.md) 6節）。

ブラウザで開いているPDF / 論文ページを、コンテキストスイッチなしでライブラリに取り込む機能。実装は2段階を想定する: 第1段階はブラウザ拡張なしのメニューバー方式（本ドキュメントの主対象）、第2段階はブラウザ拡張（→ 5.2節）。

## 1. 第1段階の方式: メニューバー常駐 + グローバルショートカット

第1段階ではブラウザ拡張を作らず、**メニューバー常駐（`NSStatusItem`）+ AppleScript（Apple Events）によるタブURL取得**で実現する。拡張のストア審査・複数ブラウザ対応コストを回避でき、Safari/Chrome系の主要ケースをカバーできる。

- メニューバーメニュー「現在のタブを取り込む」（メニューバー常駐は設定でオフ可能）
- グローバルショートカット: 既定 **⌘⇧P**（設定で変更可。実装は `NSEvent.addGlobalMonitorForEvents` ではなくCarbon `RegisterEventHotKey` 相当のラッパーを使用し、アクセシビリティ権限を不要とする）

## 2. 動作フロー

```
ショートカット / メニュー選択
  → 最前面アプリを判定 (NSWorkspace.frontmostApplication)
  → 対応ブラウザか?
      no  → 通知「対応ブラウザがアクティブではありません」
      yes → AppleScriptで現在タブのURLを取得
  → URL解析（→ 4節）
  → 確認ポップアップ（→ 6節。設定で省略可）
  → jobs へ enqueue → 取り込みパイプライン（→ [04](04-ingest-pipeline.md)）
  → 通知センターで結果通知
```

| 結果 | 通知 |
|---|---|
| 成功（enqueue完了） | 「取り込みを開始しました: {タイトル or URL}」。完了時に再度通知、クリックで該当論文を開く（`paperd://paper/{uuid}`） |
| 重複 | 「既にライブラリにあります」。クリックで既存論文を開く |
| 失敗（解析不能・取得失敗） | エラー内容と「アプリで手動取り込みを開く」アクション |

ジョブの `origin` は `url_scheme` と区別するため `app`（メニューバーはアプリの一部）とする。

## 3. 対応ブラウザとAppleScript

| ブラウザ | URL取得スクリプト |
|---|---|
| Safari | `tell application "Safari" to get URL of front document` |
| Google Chrome | `tell application "Google Chrome" to get URL of active tab of front window` |
| Microsoft Edge / Arc / Brave | Chrome互換のスクリプティング辞書。アプリケーション名のみ差し替え |

- 対応ブラウザはbundle identifierのホワイトリストで判定する（`com.apple.Safari`, `com.google.Chrome`, `com.microsoft.edgemac`, `company.thebrowser.Browser`, `com.brave.Browser`）
- **Firefoxは第1段階の対象外**: AppleScriptのタブスクリプティングに対応していないため。Firefoxユーザにはブックマークレット（→ 7節）またはPDFドロップを案内する

## 4. URL解析規則

取得したURLは以下の順で判定し、resolve処理（→ [04](04-ingest-pipeline.md) 2節）に帰着させる。

| パターン | 解釈 |
|---|---|
| `arxiv.org/abs/{id}` / `arxiv.org/pdf/{id}` | arXiv IDを抽出（バージョン番号は分離）→ arXiv API解決 |
| `doi.org/{doi}` / URL中にDOIパターン（`10.\d{4,}/...`） | DOI解決（Crossref → S2/OpenAlex補完） |
| パスが `.pdf` で終わる / HEADリクエストの `Content-Type: application/pdf` | PDFを直接ダウンロード → ローカルPDF解決（Docling抽出 + Crossref照合 → [04](04-ingest-pipeline.md) 4節） |
| 上記以外のHTMLページ（出版社ページ等） | HTMLを取得し `<meta name="citation_doi">`（Highwire Press タグ）からDOI抽出を試行。`citation_pdf_url` があればfetch候補に追加 |
| 解決不能 | エラー通知。元URLを `jobs.last_error` に記録し、手動取り込みダイアログへの導線を出す |

## 5. 権限とエラーハンドリング

### 5.1 Automation権限（Apple Events）

- 他アプリへのApple Events送信には **Automation権限**が必要。`Info.plist` に `NSAppleEventsUsageDescription` を記載し、ブラウザごとに初回送信時にシステムプロンプトが出る
- **拒否時**: AppleScript実行が `errAEEventNotPermitted (-1743)` で失敗する。専用の案内UIを表示する:
  - 「システム設定 > プライバシーとセキュリティ > オートメーション」を開くボタン
  - 代替手段（ブックマークレット / PDFドロップ）の案内
- 権限状態は `AEDeterminePermissionToAutomateTarget` で事前照会し、メニュー項目にも警告アイコンを出す

### 5.2 認証付きPDFの制約

学内プロキシ・出版社購読など**ブラウザのセッションでのみ取得できるPDF**は、アプリからの再ダウンロードでは取得できない場合がある（ログインページや403が返る）。

- 第1段階の回避策: メタデータのみ解決して `metadata_only` で登録し（部分的成功 → [04](04-ingest-pipeline.md) 6節）、通知で「PDFを取得できませんでした。ダウンロードしてドロップしてください」と案内する。ユーザがブラウザでPDFをダウンロード → アプリへドロップで `pdf_hash` 照合により既存エントリに合流する
- 根本対応は**第2段階のブラウザ拡張**: WebExtension がブラウザの認証済みセッションで取得したPDFバイナリを、localhost HTTP でアプリへそのまま送る方式

## 6. セキュリティ: ユーザ確認付き取り込み

URLスキーム（`paperd://import`）および将来のlocalhost受信は、**外部から任意のURLを注入できる入口**となる。悪意あるページが大量・不正なURLを送り込むことを防ぐため:

- 外部起源（`origin = url_scheme`、将来の拡張経由）の取り込みは**即時自動実行しない**。確認ポップアップ（取り込み対象のURL / 解決されたID を表示し、「取り込む / キャンセル」）を経て enqueue する
- メニューバー / ショートカット起源はユーザの能動操作のため、既定で確認を省略する（設定で確認必須にも変更可）
- 逆に、外部起源の確認を省略する設定も提供する（信頼できるワークフローを組むユーザ向け。既定はオフ）

## 7. paperd:// URLスキームとブックマークレット

`paperd://import?url=...`（→ [01](01-architecture.md) 6節）は、ブラウザ取り込みに限らない**汎用の外部連携入口**として位置づける。ブックマークレット・Alfred/Raycast・他ツールからの連携はすべてこのスキーマを使う。

ブックマークレット例:

```javascript
javascript:location.href='paperd://import?url='+encodeURIComponent(location.href);
```

制約:

- **Chrome内蔵PDFビューアではブックマークレットが動作しない**（PDF表示中はJavaScriptを実行できない）。PDFを開いた状態での取り込みはメニューバー / ショートカット経路（AppleScriptはビューアの状態によらずタブURLを取れる）を使う
- Firefoxではこのブックマークレットが第1段階の主要経路となる（→ 3節）

## 8. 機能マトリクス（第1段階時点）

| 経路 | Safari | Chrome系 | Firefox | PDF表示中 | 認証付きPDF |
|---|---|---|---|---|---|
| メニューバー / ⌘⇧P | ○ | ○ | ✕ | ○ | △（メタデータのみ） |
| ブックマークレット | ○ | ○ | ○ | ✕（Chrome系） | △（メタデータのみ） |
| PDFドロップ | ○ | ○ | ○ | ○（DL後） | ○（DL後） |

△ = PDF取得は失敗しうるが `metadata_only` で部分的に成功する。
