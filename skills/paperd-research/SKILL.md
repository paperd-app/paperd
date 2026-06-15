---
name: paperd-research
description: DeepResearch-style literature survey centered on the user's paperd library. Runs a clarification gate, then maps the library (search + citation-graph snowball), researches the web in parallel via subagents, reconciles findings, adds papers under a pre-agreed policy, and saves a grounded survey. Use for requests like "survey the literature on ...", "do a literature review", "find related work", or "what's the state of the art on ..." (users may phrase these in any language).
version: 3
---

# paperd Literature Survey Orchestration

You are the **lead** of a literature survey centered on the user's library. You plan, hold all
library reads/writes, delegate web/citation work to **isolated subagents**, and synthesize the
final survey yourself. This is the design in `docs/12-research-orchestration.md`.

- **Tools** are the paperd MCP server, referenced fully-qualified: `paperd:search_papers`,
  `paperd:get_fulltext`, `paperd:get_paper_metadata`, `paperd:get_citations`,
  `paperd:get_bibtex`, `paperd:add_paper`. The survey itself is saved to chat or a markdown
  file in the calling project (via the Write tool) — **not** to the library (no `add_note`).
- **Subagents** (bundled Claude Code agents). Delegate with the Task tool, in parallel:
  - `paperd-web-researcher` — one per subtopic, web-only, returns compressed candidate papers.
  - `paperd-citation-analyst` — bounded citation-graph snowball from seed papers (tier T2+).
  - If those agents are not installed, fall back to a general subagent using the inline
    contracts in "Delegating" below.
- **You (lead) own every library write and every user interaction.** Subagents never add papers.

## Phase 0 — Clarification gate (do this first)

Orchestration is expensive; a wrong premise wastes it. Ask **enough** up front — but in **one
batch**, with a recommended default per item, and **skip anything the user already gave**.
Ask at most one round; if the user says "just go", proceed with defaults.

Confirm these dimensions (offer defaults in brackets):

1. **Purpose** — related-work section / backing a specific claim / mapping a field / comparing A vs B.
2. **Scope boundaries** — subtopics and adjacent areas to include; anything explicitly out.
3. **Depth vs breadth** → effort tier (see table). [default **T1**: a focused survey]
4. **Time range** — recent N years only, or include classics/foundational work? [recent-leaning + key classics]
5. **Library-centricity** — how aggressively to chase works the user doesn't own. [library-centric]
6. **Known seeds** — papers / authors / keywords to start from.
7. **Output** — language, and where to save the survey: **chat only (default)**, a new markdown file in the calling project, or a specific path you give.
8. **`add_paper` authorization policy** (most important — prevents constant stalling):
   - **(a) allow all** — auto-add VERIFIED candidates (up to the safety cap, below).
   - **(b) allow up to N** [default **N = 5**] — auto-add the top N, list the rest as suggestions.
   - **(c) propose only** — never call `add_paper`; just present a candidate table.
   - **Default when the user defers: (c) propose only** (don't change the user's library without an explicit choice).

Once decided, **do not stop to ask per paper** — Phase 6 follows this policy silently.

## Phase 1 — Freeze a brief

Write a short frozen brief (3–6 bullets): the question, in/out scope, N non-overlapping
subtopics (N per tier), depth/breadth, output language, and the `add_paper` policy + N. This
brief is the shared context you hand to every subagent. Do not let it drift mid-run.

## Phase 2 — Map the library first (this is paperd's edge)

Before touching the web:

- `paperd:search_papers` per subtopic. Use `mode=hybrid` for conceptual queries; use
  `mode=keyword` for exact author/method/symbol matches or when a hybrid call returns
  `semantic:"warming_up"` and you need a deterministic result now.
- For pivotal hits: `paperd:get_paper_metadata` to see `sections`, then
  `paperd:get_fulltext(section=…)` to read efficiently. **Never describe a library paper's
  content from its title** — ground it in fetched full text.
- **Snowball** with `paperd:get_citations` (direction `both`) from pivotal seeds to surface
  related work. At T2+ delegate this to `paperd-citation-analyst`. Each entry carries
  `in_library` (true = owned, false = stub) and external IDs.
- If a seed's full text looks garbled or `conversion_warnings` is high, suggest the
  **paperd-fix-conversion** skill and do not ground claims on the damaged passage.

Output: a library map per subtopic (owned papers + a stub frontier with `in_library` flags).

## Phase 3 — Parallel web research (subagents)

Launch `paperd-web-researcher` subagents **in parallel — one Task call per subtopic, all in a
single message**. Give each the frozen brief, its one subtopic with scope, and a tool-call
budget (see table). Each returns a compressed digest of VERIFIED/UNVERIFIED candidates.

## Phase 4 — Cross-check & dedup

Reconcile the library map and web digests into one candidate set, classified as
**already-in-library / known-stub / genuinely-new**. Dedup by identifier, **not title**
(priority: `in_library` flag → arXiv ID → DOI → title+year only as a low-confidence last
resort). A web candidate matching a stub by DOI/arXiv becomes "known-stub → promotable".
**Quarantine UNVERIFIED web candidates** — they are not eligible for `add_paper`.

## Phase 5 — Reflect & close gaps

Take one deliberate reflection pass: which subtopics are thin, which seminal works are
conspicuously missing, is coverage sufficient? Then **stop or iterate**:

- **Stop** when ANY holds: each subtopic has enough grounded references and no obvious seminal
  gap (sufficiency); a new pass returns mostly papers you already have (diminishing returns);
  the tier's budget/iteration cap is reached.
- **Iterate** at most the tier's max iterations, and **decay**: a second pass targets only the
  weak subtopics with 1–2 narrow subagents and one fewer snowball hop. Never re-run the full
  fan-out at full breadth.

## Phase 6 — Add papers (policy-driven, no stalling)

Apply the Phase-0 policy to the genuinely-new + promotable candidates (ranked, **VERIFIED only**):

- **allow all** — `paperd:add_paper` each (prefer `arxiv_id`/`doi`; use `url` only if no
  identifier), up to the safety cap of ~10 per pass; surplus goes to "suggested".
- **allow up to N** — add the top N; list the rest as suggestions.
- **propose only** — add nothing; present the candidate table with identifiers.

Do **not** ask per paper — the policy was agreed in Phase 0. Promoting a known-stub by its
identifier absorbs it into the existing graph row. Handle async per "Async" below.

## Phase 7 — Synthesize & save

You are the single synthesizer. Produce the survey (template below) in the user's language.
Every claim must trace to a fetched source URL or a library `paperd:get_fulltext` — cut or
explicitly mark anything unbacked. Get **every** reference via `paperd:get_bibtex` (by
`paper_id` for library papers, by `doi`/`arxiv_id` for new ones) — never hand-write bibtex.

**Save** per the Phase-0 choice: always present the survey in chat; and if a file was
requested, **write a new markdown file with the Write tool** — to the path the user gave, or
by default a new file in the calling project (e.g. `./<topic-slug>-survey.md`; use a
`surveys/`-like folder only if one already exists). State the path you wrote. Do **not** write
to the library with `add_note` — the survey is a project artifact, not a paper's notes.

## Effort tiers

| Tier | Trigger | Subtopics | Web subagents | Snowball | Tool budget / web subagent | Max reflection iters |
|---|---|---|---|---|---|---|
| **T0** Lookup | "related work for X" (one narrow paper/claim) | 1 | 0–1 | 1 hop, lead inline | 3–6 | 0 |
| **T1** Focused *(default)* | "survey the literature on X" | 2–3 | 2–3 | 1 hop, lead inline | 6–10 | 1 |
| **T2** Comparison | "compare A vs B", "trade-offs" | 3–4 | 3–4 | 1–2 hops, via analyst | 8–12 | 1–2 |
| **T3** Broad review | "comprehensive review of field F" | 5–8 | 5–8 (may batch) | 2 hops decaying, via analyst | 10–15 | 2 |

Default to T1 unless there's an explicit breadth signal. `add_paper` count is governed by the
Phase-0 policy (cap ~10 per pass even under "allow all"; surplus → suggestions).

## Delegating (inline fallback contracts)

Prefer the bundled subagents — their frontmatter *enforces* the tool limits (web-only;
read-only). A general fallback subagent is **not** tool-restricted, so on this path the
"no web library access" / "never add_paper or add_note" guarantees rely on the prose contract
only; honor them strictly, and recommend installing the bundled agents for the hard guarantee.
If unavailable, spawn a general subagent with these contracts (fill the < > parts; always
include the brief, the subtopic/seeds, and the budget):

**Web researcher** — objective: research `<subtopic + scope>` for a survey on `<topic>`; tools:
WebSearch/WebFetch only, **no library access**; rules: start broad then narrow, prefer primary
sources (arXiv/publisher/Semantic Scholar/OpenAlex), a paper is VERIFIED only if you fetched a
page with title+authors+year AND a resolvable DOI/arXiv ID else UNVERIFIED, **never invent
papers/IDs**; output: compressed digest (key findings w/ URLs; candidates as title|authors|year|
DOI-or-arXiv|URL|VERIFIED/UNVERIFIED|why; seminal-vs-recent; gaps); budget: `<N>` tool calls.

**Citation analyst** — objective: snowball from seeds `<paper_id list>` direction `<both>` depth
`<1|2>`; tools: `paperd:get_citations`/`get_paper_metadata`/`get_fulltext` read-only, **never
add_paper/add_note**; rules: if `status:"fetching"` note and proceed (don't block), dedup by
in_library→arXiv→DOI; output: ranked frontier (title|year|DOI/arXiv|in_library|from-seed|hop|
why); budget: `<M>` get_citations calls.

## Anti-hallucination & source quality (hard rules)

- A paper does not exist until a source was fetched; unresolved identifier ⇒ UNVERIFIED ⇒ not
  eligible for `add_paper`.
- `add_paper` only for candidates with a resolvable DOI or arXiv ID.
- Bibtex always from `paperd:get_bibtex` — never fabricate keys/fields.
- Library claims always grounded in `paperd:get_fulltext` (not abstract/title).
- Prefer primary sources; exclude SEO farms / AI listicles / undated blogs as evidence.
- If the library has no support for a point, say so honestly — don't pad with web speculation.

## Async handling

- `add_paper` → `status:"metadata_only"`: bibliographic data is registered; PDF/convert/index
  run in the background (and may pause until the app is launched). Don't wait on it; mark such
  papers "added (pending ingestion)" and don't immediately `get_fulltext` them.
- `get_citations` → `status:"fetching"`: graph is fetching in the background. Continue other
  work; retry once after a few seconds if those edges are pivotal, else proceed with the cache.
- `get_citations` → `status:"unavailable"`: no external IDs; skip that seed's snowball.
- `search_papers` → `semantic:"warming_up"`: FTS5 results are already returned; proceed, and
  optionally re-query once the embedder is warm if recall matters. Never busy-wait.

## Survey output template

```
# Literature survey: <topic>
_Scope:_ <question + boundaries>   _Effort tier:_ <T?>   _Date:_ <date>

## Summary
<3–6 sentences: shape of the field, main camps, where the library is strong/thin>

## Per-subtopic synthesis
### <Subtopic>
- In library (grounded): <claims, each → (Author, year) of a library paper>
- Seminal works: <papers, in-library? marker>
- Recent developments: <papers, year-ordered, with source>
- Gaps / not in your library: <…>

## Library coverage map
| Paper | In library | Role | Subtopic |

## Library additions
- Added (pending ingestion): <papers added under the policy, with identifiers>
- Suggested (not added): <VERIFIED candidates not added, with identifiers>

## Open questions & gaps
<unanswered questions, contested points, under-explored directions>

## References
<one paperd:get_bibtex entry per cited paper — never hand-written>
```

## Rules (shared with paperd-cite / paperd-fix-conversion)

- `add_paper` follows the **pre-agreed Phase-0 policy** (allow all / up to N / propose only;
  default propose only) and **does not stop per paper**.
- Bibtex always via `paperd:get_bibtex`; library-content claims always via `paperd:get_fulltext`.
- Decide library membership by identifier (`in_library` / DOI / arXiv), not by title.
