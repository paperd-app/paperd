# paperd 開発ガイド

## 設計書と実装の整合性（最重要）

**設計書(`docs/`)は常に「現在の設計＝実装の実態」を記述する。** 機能追加・設計変更の際は、先に該当する設計書を更新してから実装に移り、設計書とコードの整合性を維持すること。

- 設計判断（なぜその方式か）は設計書に書く。当初案から実装で変更した場合も設計書本文を新しい設計に書き換え、変更理由は日付つきの短い注記として該当節に追記する（例: docs/02 の設計変更ノート）。
- 設計書の該当箇所はコード内コメントから `→ docs/XX` 形式で参照する（既存コードの慣例に従う）。
- 未実装・既知の課題・実装予定は GitHub Issues、リリース履歴は git / GitHub Releases で管理する。

## ビルド・テスト

```sh
swift build               # 全ターゲット（要Xcode）
swift test                # Swiftテスト（Swift Testing）
# Pythonワーカーのテスト（初回は .venv を作成）
cd worker && python3.11 -m venv .venv && .venv/bin/pip install -e ".[dev]"
cd worker && .venv/bin/pytest
```

## 構成の要点

- `Sources/PaperdCore/` — アプリとMCPが共有するロジック。UIに依存させない（テスト可能性のため）
- `Sources/PaperdMCPKit/` — MCPサーバロジック（stdio JSON-RPC自前実装）。CLI本体（PaperdMCP）と分離
- `worker/` — Pythonワーカー（venv + pip）。Docling / Qwen3-Embedding MLX は遅延import（テストは軽量依存のみで動く）
- ファイルが正本・SQLiteは再構築可能なインデックス（→ docs/03）。この原則を壊す変更をしない
