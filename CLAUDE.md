# paperd 開発ガイド

## 設計書と実装の整合性（最重要）

**設計書に書かれていない機能を実装する際は、先に `docs/` 内の設計書を更新してから実装に移り、設計書と実装の整合性を維持すること。**

- 設計判断（なぜその方式か）は設計書に、実装都合の乖離は `README.md` の「設計書からの主な乖離」に記録する
- 設計書の該当箇所はコード内コメントから `→ docs/XX` 形式で参照する（既存コードの慣例に従う）

## ビルド・テスト

```sh
swift build               # 全ターゲット（要Xcode）
swift test                # Swiftテスト（Swift Testing）
cd worker && uv run pytest  # Pythonワーカーのテスト
```

## 構成の要点

- `Sources/PaperdCore/` — アプリとMCPが共有するロジック。UIに依存させない（テスト可能性のため）
- `Sources/PaperdMCPKit/` — MCPサーバロジック（stdio JSON-RPC自前実装）。CLI本体（PaperdMCP）と分離
- `worker/` — Pythonワーカー（uv管理）。Docling / bge-m3 は遅延import（テストは軽量依存のみで動く）
- ファイルが正本・SQLiteは再構築可能なインデックス（→ docs/03）。この原則を壊す変更をしない
