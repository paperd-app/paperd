# 12. 文献調査オーケストレーション（paperd-research）

`paperd-research` スキルは、ユーザの**ライブラリを中心に据えた**文献調査（DeepResearch風サーベイ）を担う。
本章はその設計を定める。MCPツール群（→ [07](07-mcp-server.md)）と引用グラフ（→ [08](08-citation-graph.md)）を
オーケストレーションする複雑タスクであり、**委譲の作法・工数配分・捏造防止・停止条件**といった設計判断が品質を左右する。

> スキル/エージェントの実体はリポジトリの `skills/` `agents/` で管理し、英語で記述する
> （読み手はAI。国際配布でも単一言語でよい → [09](09-ui.md) 10節）。本章のJSON例・契約テンプレートの
> 説明は設計書の可読性のため日本語で記すが、**実装では同内容の英語**とする。

## 1. 位置づけと方針

薄いスキル（手順の箇条書き）では不十分で、オーケストレーションの肝は**サブエージェントへの委譲契約**にある。
本設計は、既存の DeepResearch のグッドパターン（Anthropic multi-agent research / LangChain Open Deep Research /
GPT-Researcher / dzhng/deep-research / STORM）を踏襲しつつ、paperd 固有の強みを活用する。

- **踏襲するグッドパターン**: orchestrator-worker（lead が計画・分解・統合、subagent が隔離コンテキストで圧縮結果を返す）/
  委譲契約（目的・出力形式・ツール&ソース指針・境界）/ 工数の複雑度スケーリング / 反復と停止条件 /
  research は並列・writing は直列 / 引用の接地（fetched source に基づく）
- **paperd 固有の差別化**: 調査の起点は web ではなく**ユーザのライブラリ**。`search_papers` で所持文献を地図化し、
  `get_citations` の引用グラフ snowball で関連研究をたどる（`in_library` で所持判定、stub は `add_paper` で昇格）。
  調査結果は**チャット、または呼び出し元プロジェクト内の新規 Markdown（あるいはユーザ指定先）**に保存する
  （ライブラリの論文ノートには書き込まない → 3.7, 7節）
- **兄弟スキルとの関係**（→ 10節）: `paperd-cite`（執筆引用）、`paperd-fix-conversion`（変換修正）と規約を共有する

## 2. トポロジ：lead skill ＋ 2 サブエージェント定義

### 2.1 採用形

**lead = `paperd-research` スキル（メインコンテキスト常駐）** が、同梱の**サブエージェント定義**へ Task で委譲する。

| 構成要素 | 実行場所 | 責務 |
|---|---|---|
| **lead**（`paperd-research` skill） | メインコンテキスト | スコープ明確化・計画・ライブラリ読み書き・dedup の単一所有・最終 synthesis・`add_paper`・結果の保存（チャット/プロジェクトの Markdown） |
| **subagent A**（`paperd-web-researcher`） | 隔離コンテキスト | 割当 1 サブトピックの **web 調査のみ**。圧縮済み・出典付き digest を返す |
| **subagent B**（`paperd-citation-analyst`） | 隔離コンテキスト | seed から `get_citations` の **bounded snowball**。`in_library` 付き frontier を返す |

**lead に責務を残す理由**:

- **ライブラリへの書き込みは lead のみ**。`add_paper` はユーザ資産の変更であり、認可ポリシー（→ 3.0節）の
  単一の番人を置く。N 体の隔離サブエージェントに書き込みを分散させない。サーベイ結果の保存
  （プロジェクトファイル書き込み）も同期・整合のため lead が一手に行う
- **ライブラリ状態の単一所有**。snowball が生む `in_library`/stub の集合は、累積 dedup（→ 6節）のため単一の所有者が持つ
- **writing は直列**。最終サーベイは単一の synthesizer（lead）が書く（並列に節を書くと不整合になる）

**サブエージェント定義を同梱する理由**（inline Task ではなく定義をシップする）:

- **ツール許可リストを固定**できる。web-researcher に `paperd:*` を一切持たせない＝**捏造・誤書き込みの構造的防止**
- **モデルを固定**できる。サブエージェントは **Sonnet 以上**（breadth/探索でも判断品質が要るため Haiku は使わない）、
  lead の reflection/synthesis は最上位モデル（→ 4節）
- 再利用可能でユーザが**検査できる**（skill と同じ配布形態 → [07](07-mcp-server.md) 6.2節）
- `context: fork` を主機構にしない理由: fork は親のツール付与とコンテキストを共有し、ツール許可リストの**ハードな隔離**が
  効かない。捏造防止と「書き込みは lead のみ」の境界が曖昧になる。定義不在環境のための inline-Task フォールバックは残す

### 2.2 サブエージェント A: `paperd-web-researcher`

| 項目 | 値 |
|---|---|
| 目的 | 割当 1 サブトピックを**オープン web のみ**で調査。最近の動向と候補論文を、解決可能な識別子つきで圧縮して返す |
| tools | `WebSearch` / `WebFetch` のみ。**`paperd:*` 不可**（ライブラリに触れない＝捏造・書き込みの構造境界） |
| model | **Sonnet（下限。Haiku は性能不安のため不可）**。最重要サブトピックは上位モデルに格上げ可（→ 4節） |
| 出力 | OUTPUT FORMAT に限定した digest（生ページのダンプ禁止） |

### 2.3 サブエージェント B: `paperd-citation-analyst`

| 項目 | 値 |
|---|---|
| 目的 | seed `paper_id` 群から `get_citations`（references/citations）で **bounded snowball**。`in_library` 付きの dedup 済み frontier をランク化して返す |
| tools | `paperd:get_citations` / `paperd:get_paper_metadata` / `paperd:get_fulltext`（**read-only**、`add_*` 不可）。定義の `tools:` フロントマターでは正規識別子 `mcp__paperd__<tool>` で記す（→ [07](07-mcp-server.md) 6.3節） |
| model | **Sonnet（下限。Haiku は性能不安のため不可）**。探索は機械的 fan-out + ランク付けだが、関連性判断に Sonnet を要する |

**caveat（設計上明記）**: `get_citations` は read だが、キャッシュ失効時に `refetch_citations` ジョブを短く投入し
`status:"fetching"` を返しうる（→ [07](07-mcp-server.md) 3節, [08](08-citation-graph.md) 3節）。これは**承認不要の背景処理**で
ユーザに見える変更を伴わないため、「ライブラリ書き込みは lead のみ」原則と矛盾しない。snowball を lead に残す代替案もあるが、
ハブ論文で数百 stub を返しうるため、隔離コンテキストで圧縮 frontier だけを返す利得を優先する。

### 2.4 委譲契約テンプレート（verbatim）

lead は以下のブロックを組み立てて Task のプロンプトに渡す。Anthropic の4要素 **objective / output format /
tool & source guidance / boundaries** を必ず埋める（欠けると subagent は作業重複・取りこぼし・誤探索を起こす）。

`paperd-web-researcher` 用:

```
ROLE: paperd-web-researcher (isolated subtopic research)

OBJECTIVE
  Research this single subtopic for a literature survey on "<MASTER TOPIC>":
    <SUBTOPIC TITLE>
    <1-3 sentence scope: what is in-scope, what is explicitly out>
  Frozen survey brief (shared context):
    <2-4 bullet excerpt relevant to this subtopic>

TOOL & SOURCE GUIDANCE
  - Start broad, then narrow: 1 broad query to map the space, then 2-4 targeted queries.
  - PREFER primary sources: arXiv, publisher pages, Semantic Scholar, OpenAlex, ACL/NeurIPS/etc.
  - AVOID SEO content farms, blog roundups, AI-generated listicles as evidence.
  - For every candidate paper you report, you MUST have FETCHED a page stating its
    title + authors + year, and captured a resolvable DOI or arXiv ID from that page.
    If you cannot resolve an identifier, mark the paper UNVERIFIED.

OUTPUT FORMAT (return ONLY this, compressed - no raw page dumps)
  ## Subtopic: <title>
  ### Key findings (3-8 bullets, each with an inline source URL)
  ### Candidate papers
    For each: title | authors (et al. ok) | year | DOI or arXiv ID | source URL
             | VERIFIED|UNVERIFIED | 1-line why it matters
  ### Seminal vs recent (label each candidate)
  ### Open questions / gaps you noticed

BOUNDARIES
  - Tool budget: <N> total tool calls (WebSearch + WebFetch). Stop when you hit it.
  - Do NOT call any paperd:* tool. You have no library access.
  - Do NOT invent DOIs, arXiv IDs, or papers. Unverifiable -> UNVERIFIED or omit.
  - Do NOT write prose beyond the OUTPUT FORMAT. Return the digest, not a narrative.
  - Prefer a smaller VERIFIED set over an exhaustive unverified one.
```

`paperd-citation-analyst` 用（同じ骨格）:

```
ROLE: paperd-citation-analyst (bounded snowball over the library citation graph)

OBJECTIVE
  Snowball from these seeds (pivotal library papers):
    <paper_id list + titles>
  Direction: <references | citations | both>   Depth: <1 | 2>

TOOL & SOURCE GUIDANCE
  - Call paperd:get_citations per seed (read-only). If status is "fetching", NOTE it
    and proceed with whatever the cache returned - do NOT block or busy-wait.
  - Dedup the frontier by external ID (in_library flag, then arXiv ID, then DOI).

OUTPUT FORMAT (return ONLY this, compressed)
  ### Frontier (ranked)
    For each: title | year | DOI/arXiv | in_library (true/false) | from-seed | hop | why-pivotal

BOUNDARIES
  - Tool budget: <M> get_citations calls. Read-only.
  - Never call add_paper / add_note. You cannot write to the library.
```

## 3. ワークフロー（フェーズ状態機械 0–7）

各フェーズに **入力 / 使用ツール / 出力 / 停止・反復ルール** を定める。Phase 0–2 と 5–7 は **lead**、Phase 3 は
**サブエージェント**へ fan-out、Phase 4 は lead で reconcile する。ツールは全て `paperd:` 完全修飾で呼ぶ（→ 9節）。

### 3.0 Phase 0 — スコープ明確化ゲート（最重要）

オーケストレーションは高コスト（multi-agent は chat の ~15 倍 token）。**誤った前提での実行を避ける投資**として、
調査開始前に結果を左右する次元をユーザに確認する。既存スキルの「質問は最大1つ」を撤回し、**十分な明確化質問を行う**。

**確認する次元（チェックリスト。該当項目を1ターンにまとめて提示）**:

1. 調査の目的・用途（関連研究節の執筆 / 特定主張の裏付け / 分野の全体像把握 / 手法 A vs B 比較 など）
2. 範囲の境界（含めるサブトピック・隣接領域、明示的に除外するもの）
3. 深さ vs 広さ（→ effort tier T0–T3 にマップ。重要数本でよいか / 網羅的レビューか）
4. 時間範囲（最近 N 年限定か / 古典・基礎文献を含むか）
5. ライブラリ中心度（探索の広さ＝未所持の重要論文をどの程度積極的にたどるか）
6. 既知の seed（起点にしたい論文・著者・キーワード）
7. 出力（言語・形式、サーベイの保存先＝チャットのみ（既定）／プロジェクト内の新規 Markdown／ユーザ指定パス）
8. **`add_paper` 認可ポリシー**（下記。最重要）

**第8項 `add_paper` 認可ポリシー（調査前に一度だけ決定 → Phase 6）**: 従来の「論文ごとに承認」は**頻繁に停止して
使い物にならない**ため撤回し、**開始前に1度だけ方針を確定**して以後は停止せず進める。

| ポリシー | 動作 |
|---|---|
| (a) 全許可 | VERIFIED 候補を tier の探索幅ぶん自動追加（安全上限 → 4節） |
| (b) N本まで許可（**既定 N=5**） | 上位 N 本を自動追加し、残りは「未追加の提案候補」として提示 |
| (c) 許可しない＝提案のみ | `add_paper` を呼ばず、識別子つき候補表のみ提示 |

**「お任せ」既定 = (c) 提案のみ**（ユーザ資産であるライブラリを明示同意なく変更しない安全側）。N の値や方針はこの
1ターンで併せて確認する。

**運用ルール**:

- (a) **複数質問を1ターンにまとめ**、各質問に推奨デフォルトを併記して往復を最小化
- (b) **ユーザが既に与えた情報は再質問しない**
- (c) 各質問は「お任せ（既定）」可。ユーザが「とにかく始めて」と言えば既定（T1・ライブラリ中心・最近重視・
  add_paper=提案のみ）で即進む＝**ブロックしすぎない**
- (d) 明確化は**最大1ラウンド**（回答を得たら即 Phase 1 へ。延々と聞き返さない）

**出力**: ユーザ回答（または既定）。これが Phase 1 の凍結 brief と effort tier（→ 4節）に落ちる。

```
明確化ゲート(Phase 0) ──回答/既定──▶ effort tier 選定(§4)
                                   └▶ 凍結 brief(Phase 1) ──▶ Phase 2 以降
```

### 3.1 Phase 1 — brief を凍結

- **入力**: 明確化の回答 + effort tier
- **ツール**: なし
- **出力**: 短い**凍結 brief**（3–6 箇条）。調査の問い、in/out スコープ境界、N 個の重複しないサブトピック分解、
  目標 depth/breadth、出力言語、`add_paper` ポリシー。**検索前に凍結**し、途中でドリフトさせない
- **停止ルール**: brief が存在し、tier に応じた N 個の非重複サブトピックを名指ししている

### 3.2 Phase 2 — library-first mapping（lead）

paperd の差別化点。web に触れる前に**ユーザのライブラリを地図化**する。

- **入力**: 凍結 brief、サブトピック一覧
- **ツール**:
  - `paperd:search_papers`（サブトピックごと）。**mode の使い分け**: 概念的サブトピックは `mode=hybrid`、
    固有名詞・手法名・記号の完全一致や、`semantic:"warming_up"` 返却時に即時の決定的結果が要るときは `mode=keyword`
  - pivotal hit に `paperd:get_paper_metadata`（`sections[]` を見る）→ `paperd:get_fulltext(section=…)` でトークン制御
  - **snowball**: `paperd:get_citations`（直接、または高 tier では `paperd-citation-analyst` へ委譲）
- **出力**: **ライブラリ地図**（サブトピック別の所持論文 `paper_id`、pivotal seed、snowball で得た **stub frontier**＝
  各 `in_library` フラグ + 外部ID付き）
- **停止ルール**: 各サブトピックを検索済み。snowball の hop は tier の上限と予算に従う。ハブ論文は引用上限
  （取得段で1,000件 → [08](08-citation-graph.md) 3節）まで返ったら展開を止める
- **品質ルール**: ライブラリ論文の内容は**必ず `get_fulltext` に接地**して述べる（タイトルからの推測禁止）。
  `conversion_warnings` が高い／本文が文字化けしている seed は `paperd-fix-conversion` を促し、garbled 本文に
  接地しない（→ 10節）

### 3.3 Phase 3 — 並列 web 調査（サブエージェント）

- **入力**: 凍結 brief + 1 サブトピックずつ
- **ツール**: `paperd-web-researcher` を**並列起動**（1 サブトピック1体）。各々に 2.4 の契約と tool 予算（→ 4節）
- **出力**: N 個の圧縮 digest（findings + VERIFIED/UNVERIFIED 候補 + seminal/recent + gaps）
- **停止ルール**: 全 subagent が返却または予算到達。予算切れの部分結果は許容（lead は無限待機しない）

### 3.4 Phase 4 — cross-check & dedup（lead）

- **入力**: ライブラリ地図（Phase 2）+ web digest（Phase 3）
- **ツール**: `paperd:search_papers`（境界事例の識別子照合）。`get_citations` 結果は既に `in_library` を持つ
- **出力**: 単一の reconciled 候補集合を **already-in-library / stub-known / genuinely-new** に分類。dedup は
  6節（識別子ベース）に従う。**UNVERIFIED の web 候補は隔離**（`add_paper` 不可 → 5節）
- **停止ルール**: 全 web 候補が分類済み

### 3.5 Phase 5 — reflection / gap ループ（lead）

監査で欠落と指摘した明示的「think」ステップ。

- **入力**: reconciled 集合 + brief
- **ツール**: 推論（意図的な reflection ターン）。必要なら最弱サブトピックに 1 回だけ追加 `search_papers`/`get_citations`
  または follow-up サブエージェント1体
- **出力**: ギャップ評価（薄いサブトピック、明らかに欠けた seminal works、被覆が十分か）
- **停止条件（いずれか成立で離脱。固定ループ回数ではない）**:
  1. **充足**: 各サブトピックが tier の最小数以上の接地済み参照（in-library or VERIFIED）を持ち、明白な seminal gap が無い
  2. **重複検出**: 新たな反復が既出の論文ばかりを返す（収穫逓減）
  3. **予算**: tier の総ツール予算 / 反復上限に到達
- **反復ルール**: 反復は tier の最大回数まで（→ 4節）。再帰時は **breadth/depth を減衰**（2 巡目は特定ギャップに
  狭く1–2体、snowball hop を1段下げる）。全 fan-out を全幅で再実行しない

### 3.6 Phase 6 — ポリシー駆動 `add_paper`（停止しない）

- **入力**: genuinely-new + 昇格可能 stub 候補（ランク済み）+ Phase 0 で確定したポリシー
- **ツール**: ポリシーに従い `paperd:add_paper`（`arxiv_id`/`doi` 優先、識別子があれば `url` は使わない）
  - **(a) 全許可**: VERIFIED 候補を自動追加（安全上限 → 4節、超過分は「提案」へ）
  - **(b) N本まで**: 上位 N 本を追加、残りは「未追加の提案候補」として列挙
  - **(c) 提案のみ**: `add_paper` を呼ばず候補表（識別子付き）を提示
- **出力**: 追加した `paper_id`（多くは `status:"metadata_only"`）+ 未追加候補リスト
- **安全・停止ルール**: いずれも**VERIFIED のみ**が対象（→ 5節）。ポリシーは Phase 0 で合意済みのため、**論文ごとの
  確認はしない**＝停止しない。stub はその識別子で `add_paper` すると既存 stub 行に吸収される（→ [08](08-citation-graph.md) 4節）。
  非同期は 8節

### 3.7 Phase 7 — synthesize ＋ 永続化（lead、単一 synthesizer）

- **入力**: 上記すべて
- **ツール**: 引用ごとに `paperd:get_bibtex`（手書き禁止）。結果は**チャット出力**＋（Phase 0 で指定時）
  **呼び出し元プロジェクト内の新規 Markdown** を Write ツールで書き出し（`add_note` は使わない）
- **出力**: サーベイ（→ 7節）をチャットに出力。保存先が指定されていれば、プロジェクト内の新規 Markdown
  （既定 `./<topic>-survey.md`）またはユーザ指定パスに保存。ライブラリ（`add_note`）には書き込まない
- **停止ルール**: サーベイの全 claim が fetched source または `get_fulltext` に接地（**引用接地は最終の独立パス** → 5節）。
  出力はユーザの言語で

## 4. 工数スケーリング規律（T0–T3）

tier は Phase 0 で request の形から選ぶ。予算は**上限**であり目標値ではない。

| Tier | トリガ（request の形） | サブトピック | web subagent | snowball hop | tool 予算/web subagent | lead ライブラリ呼び出し上限 | 最大 reflection 反復 |
|---|---|---|---|---|---|---|---|
| **T0 Lookup** | 「X の関連研究」単一の狭い論文/主張 | 1 | 0–1 | seed 1–2 から 1 hop | 3–6 | ~8 | 0 |
| **T1 Focused**（既定） | 「X の文献調査」単一の主題 | 2–3 | 2–3 | pivotal seed から 1 hop | 6–10 | ~20 | 1 |
| **T2 Comparison** | 「A vs B の比較」「トレードオフ」 | 3–4（各陣営1） | 3–4 | 1–2 hop | 8–12 | ~30 | 1–2 |
| **T3 Broad review** | 「分野 F の網羅的レビュー」 | 5–8 | 5–8（並列上限・バッチ可） | 2 hop 減衰 | 10–15 | ~50 | 2 |

- **不確かなら T1 を既定**。明示の breadth シグナルでのみ escalate
- `paperd-citation-analyst` は **T2 以上**で使う（fan-out が隔離を正当化）。T0/T1 は lead が inline で snowball
- **モデル割当**: サブエージェントは **Sonnet を下限**とする（Haiku はオーケストレーションの判断品質に不安があるため
  使わない）。T3 の最中心サブトピックの web subagent は上位モデルに格上げ可。**lead は常に最上位モデル**（Phase 5
  reflection と Phase 7 synthesis）。サブエージェント定義の `model` frontmatter で固定する（→ [07](07-mcp-server.md) 6.2節）
- **`add_paper` 上限は Phase 0-⑧ のポリシーが支配**: N本まで＝N、全許可＝tier の探索幅。ただし**暴走防止の
  安全上限 ≤10/pass を既定**とし、超過分は自動追加せず「提案」に回す（ライブラリ氾濫を避ける）

## 5. 捏造防止・ソース品質ルール（学術特化）

今日のスキルに対する最重要の追加。lead スキルと web-researcher 契約の両方に明示する。

1. **fetched しない限り論文は存在扱いしない**。web subagent は、タイトル+著者+年を述べるページを**実際に fetch**した
   論文だけを実在として報告する。さもなくば `UNVERIFIED`
2. **解決可能な識別子が無ければ `add_paper` 不可**。対象は DOI または arXiv ID が解決する候補のみ
3. **bibtex は必ず `get_bibtex`**（library は `paper_id`、新規は `doi`/`arxiv_id`）。キー・フィールドを捏造しない
4. **ライブラリの主張は `get_fulltext` に接地**（abstract やタイトルからの推測禁止）
5. **ソース品質の優先順**: arXiv / 出版社 / Semantic Scholar / OpenAlex / 主要会議録（一次）＞ 大学・研究室ページ ＞
   評判のよい二次まとめ。**SEO ファーム・AI 生成リスト・無日付ブログまとめは evidence から除外**（lead にはなりうるが
   一次資料で再検証する）
6. **引用接地は Phase 7 の独立パス**。出力前に全 claim を fetched source URL または library `get_fulltext` に突き合わせ、
   裏付けの無い claim は削るか「エージェントの推論」と明記する
7. **正直な negatives**。ライブラリに根拠が無ければそう言う（`paperd-cite` と同じ規律）。web 由来の推測を
   ライブラリ知見のように水増ししない

## 6. 重複排除（識別子ベース）

脆い title 一致を、優先順つきのキーで置き換える。

1. `get_citations` の **`in_library` フラグ**（snowball で到達したものに対し権威的。追加照合不要）
2. **arXiv ID**（正規化: version 接尾辞 `vN` を除去・小文字化・`arXiv:` 接頭を除去。`10.48550/arXiv.XXXX` 形式の DOI も等価）
3. **DOI**（正規化: 小文字化・`https://doi.org/` を除去）
4. **title+year ファジー**（最後の手段。低信頼で、この候補は 5節により `add_paper` 不可）

dedup は Phase 4 で3プール（ライブラリ地図・stub frontier・web 候補）横断で走る。web 候補が stub と（DOI/arXiv で）
一致したら「stub-known → 昇格可能」に再分類する。昇格は同一識別子で既存 stub 行に吸収され、引用エッジは保たれる
（→ [08](08-citation-graph.md) 4節）。

## 7. サーベイ出力テンプレートと保存先

サーベイは（ユーザの言語で）**常にチャットに出力**する。加えて Phase 0 で保存先が指定されていれば、
**呼び出し元プロジェクト内の新規 Markdown ファイル**（既定 `./<topic-slug>-survey.md`。`surveys/` 等の慣例フォルダが
既にあればそこへ）または**ユーザ指定パス**へ Write ツールで書き出し、書き込んだパスを明示する。
**ライブラリの論文ノート（`add_note`）には書き込まない**——サーベイはプロジェクトの成果物であって、ユーザ資産たる
論文ノートではない（呼び出し元で版管理・編集できる利点もある → 11節）。

```
# Literature survey: <topic>
_Scope:_ <凍結 brief の問い+境界>   _Effort tier:_ <T?>   _Date:_ <date>

## Summary
<3-6 文: 分野の形、主な陣営、ユーザのライブラリが強い/薄い領域>

## Per-subtopic synthesis
### <Subtopic 1>
- In library (grounded): <claim ごとに (Author, year) のライブラリ論文に接地>
- Seminal works: <論文、in-library? マーカー>
- Recent developments: <論文、年順、出典付き>
- Gaps / not in your library: <…>
(サブトピックごとに繰り返し)

## Library coverage map
| Paper | In library | Role (seminal/recent/method) | Subtopic |

## Library additions
- Added (pending ingestion): <ポリシーで追加した論文。識別子付き>
- Suggested (not added): <未追加の提案候補。識別子付き。VERIFIED のみ>

## Open questions & gaps
<未解決の問い、係争点、未開拓の方向>

## References
<引用ごとの get_bibtex 出力。library は paper_id、新規は doi/arxiv。手書き禁止>
```

保存先が指定されなければチャット出力のみとする。

## 8. 非同期処理（`fetching`）

`get_citations` と `add_paper` は同じ非同期パターンを共有する（→ [07](07-mcp-server.md) 2.5, 2.8, 3節、
[10](10-roadmap-risks.md) R3）。統一ポリシー:

- **`add_paper` → `status:"metadata_only"`**（背景 ingest）: 書誌登録済み・PDF/変換/索引化は背景で進む（**アプリ未起動なら
  保留**）旨をユーザに伝える。サーベイは ingest を待たない。サーベイ上は「added (pending ingestion)」と注記し、
  追加直後の `get_fulltext` で全文を期待しない
- **`get_citations` → `status:"fetching"`**: 背景でグラフ取得中。**他の作業を進め**、pivotal なら数秒後にリトライ。
  なお `fetching` なら whatever cache を使って続行し「citation graph still warming」と注記する
- **`get_citations` → `status:"unavailable"`**: 外部ID無しでグラフ不能。その seed の snowball は省略し search + web に頼る
- **`search_papers` → `semantic:"warming_up"`**: FTS5 結果は既に返っている。続行し、recall が要るサブトピックは warm 後に再クエリ
- **busy-wait 禁止**: interleave が要点。非同期（snowball・add）を早く起動し、他フェーズを進め、最後に reconcile する

## 9. MCP ツールの利用パターン

- 全ツールを **`paperd:` 完全修飾**で参照（`paperd:search_papers` 等 → [07](07-mcp-server.md) 6.3節）
- `search_papers` の `mode`: 概念検索は `hybrid`、固有名詞・記号・コード片の完全一致は `keyword`
- 大きな論文は `get_paper_metadata` の `sections[]` を見てから `get_fulltext(section=…)` でトークン制御
- 8 ツールの呼び出し定石（→ [07](07-mcp-server.md) 2節）に従う。本スキルが使う MCP 書き込みは
  `add_paper` のみ（`add_note` は使わない）。サーベイ結果はライブラリでなく**プロジェクトファイル**へ保存する（→ 7節）

## 10. paperd-cite / paperd-fix-conversion との関係

3 スキルは規約を共有する家族として設計する。

- **`paperd-cite` は research の add 規約を継承**。cite は「ライブラリに根拠が無く web 探索するとき paperd-research の
  追加規約に従う」と定めており、本改訂後はそれが §5（捏造防止: VERIFIED + 解決可能識別子）、§6（識別子 dedup）、
  §3.0-⑧/Phase 6（**事前合意の認可ポリシー**）を指す。**add_paper 契約の正本は paperd-research**（cite は参照のみ・逸脱させない）。
  cite の接地規律（全文照合・タイトルで引用しない）は research の Phase 7 接地パスと同じ
- **`paperd-fix-conversion` と `conversion_warnings`**。`get_paper_metadata` は `conversion_warnings`（件数）と
  `has_corrections` を返す。pivotal なライブラリ論文を `get_fulltext` で読んで本文が garbled、または
  `conversion_warnings` が高いときは、garbled 本文に接地せず `paperd-fix-conversion` を促す（Phase 2 ルール）。
  fix-conversion が、research と cite の両方が読む基盤テキストを改善する
- **3 スキル共通不変条件**: **`add_paper` は事前合意ポリシー（全許可/N本まで/提案のみ・既定=提案のみ）に従い
  論文ごとには停止しない** / bibtex は `get_bibtex` / ライブラリ主張は `get_fulltext` / ライブラリ所属は識別子で判断

## 11. 設計判断と既知のトレードオフ

| 判断 | 採用理由 / トレードオフ |
|---|---|
| **`add_paper` を per-paper 承認 → 事前合意ポリシーへ** | per-paper 承認は頻繁停止で使い物にならない。1度だけ方針を決め以後停止しない。既定=提案のみで安全側（ユーザ資産を明示同意なく変更しない） |
| lead skill + 同梱サブエージェント定義（inline/fork でなく） | ツール許可リスト固定（捏造・誤書き込み防止）とモデル固定の利得。定義不在環境のための inline-Task フォールバックは残す |
| サブエージェントのモデル下限を **Sonnet** に | Haiku は本オーケストレーションの判断品質（ソース検証・関連性判断・指示追従）に不安があるため下限を Sonnet とする。token コストは増えるが、捏造・取りこぼしの低減を優先（lead は最上位モデル） |
| citation-analyst が read-only でも `fetching` ジョブを生む | ハブ論文での隔離・圧縮の利得が、承認不要の背景ジョブのコストを上回る。代替（snowball を lead に残す）も可 |
| 並列 web vs 逐次 | 並列は速いが token/overlap コスト。契約の圧縮を厳格にして overlap の reconcile を安くする |
| サーベイ保存先を `add_note`（ライブラリ）→ **プロジェクトの Markdown** へ変更 | サーベイはプロジェクトの成果物。ユーザ資産たる論文ノートを汚さず、呼び出し元で版管理・編集できる。チャット/新規 Markdown/ユーザ指定先から選ぶ（既定はチャット）。再検索性（reindex）は失うが論文ノートと混ざらない方を優先。stub 論文への `add_note` が失敗する問題も解消 |
| アプリ未起動時 ingest 未完了 | 追加論文の全文索引が当該セッション中に完了しないことがある。任意の UX nudge（「paperd を起動して N 件の取り込みを完了してください」）|
| agent 同梱＝新規配布経路 | skill のみだった配布に agents/ + install を追加（実装依存 → [07](07-mcp-server.md) 6.2節）|
