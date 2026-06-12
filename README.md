# paperd

## Installation

```sh
brew install --cask paperd-app/paperd/paperd   # recommended (installs uv automatically)
```

Or download the zip directly from [GitHub Releases](https://github.com/paperd-app/paperd/releases).
After the first launch, run "Set up environment" in Settings > Worker (takes a few minutes, 2–3 GB).

## License

[FSL-1.1-Apache-2.0](LICENSE.md) (Functional Source License).
Personal, research, educational, and internal use are all free. Only redistribution as a
competing commercial product is restricted, and each release automatically converts to
Apache 2.0 two years after publication.

paperd is a reference-management app for academic research (design docs: [docs/](docs/00-overview.md), in Japanese).

A macOS-native app built around local-AI full-text semantic search and AI integration via MCP.
It follows the design principle that files are the source of truth and SQLite is a rebuildable index.

## Layout

```
Package.swift             # SwiftPM (Swift 6.2 / macOS 14+)
Sources/
  PaperdCore/             # Shared logic (linked by both the app and MCP → docs/01)
    Database/             #   GRDB schema & migrations (→ docs/02)
    Library/              #   Library layout, meta.json, index rebuild (→ docs/03)
    Bibtex/               #   BibTeX generation, citation keys (→ docs/02 §2)
    Metadata/             #   arXiv / Crossref / S2 / OpenAlex clients & resolution order (→ docs/04 §3)
    Chunking/             #   DoclingDocument parsing, section-aware chunking (→ docs/06 §2)
    Search/               #   FTS5 + vector KNN + RRF hybrid search (→ docs/06 §4)
    Jobs/                 #   Job queue with exponential backoff (→ docs/04 §7)
    Ingest/               #   6-stage ingest pipeline, JobRunner actor (→ docs/04)
    Worker/               #   Python worker HTTP client, worker.lock (→ docs/05, 01 §3)
  PaperdMCPKit/           # MCP server logic (hand-rolled stdio JSON-RPC + 7 tools → docs/07)
  PaperdMCP/              # paperd-mcp CLI
  Paperd/                 # SwiftUI app (3-pane UI, search, citation graph, settings)
Tests/PaperdTests/        # Swift tests (Swift Testing)
worker/                   # Python worker (FastAPI / Docling / bge-m3 → docs/05)
skills/                   # Bundled Claude skills (installable from Settings)
docs/                     # Design docs (Japanese)
```

## Build & test

### Swift (PaperdCore / MCP / app)

```sh
swift build               # all targets
swift test                # full test suite (Swift Testing)
scripts/make-app.sh --open  # run the app (recommended: builds and opens the .app bundle)
swift run Paperd          # direct run also works (some OS integration is incomplete without a bundle)
```

> **Use `scripts/make-app.sh --open` to test the app.** `swift run` launches a bare,
> unbundled process, so macOS app integration is incomplete (keyboard focus issues, no
> URL-scheme registration, no Dock presence). The focus problem is worked around in code,
> but a bundled run also exercises the `paperd://` scheme and the real MCP helper path
> (Contents/Helpers/paperd-mcp) exactly as designed.

Xcode is required (Swift Testing is unavailable with Command Line Tools alone, so `swift test` won't run).

### Python worker

```sh
cd worker
uv sync                   # development (lightweight: FastAPI + pytest only)
uv run pytest             # tests
uv sync --extra ml        # production (Docling + sentence-transformers, 2–3 GB)
uv run paperd-worker --token SECRET --port 0   # start ({"port": N} is printed to stdout)
```

### MCP server

```sh
swift build
echo '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}' | .build/debug/paperd-mcp
```

Environment variables:

| Variable | Meaning |
|---|---|
| `PAPERD_LIBRARY` | Library location (default `~/PaperdLibrary`) |
| `PAPERD_WORKER_DIR` | Location of `worker/` (for on-demand worker startup for semantic search) |
| `PAPERD_MAILTO` | Email for the Crossref / OpenAlex polite pools |
| `PAPERD_S2_API_KEY` | Semantic Scholar API key (optional) |

Example registration for Claude Code (`.mcp.json`):

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

## Localization

The app UI is localized (English / Japanese, following the system language; base language is
Japanese → docs/09 §10). Strings in PaperdCore, the CLIs, MCP tool definitions/outputs, and
the bundled skills are English-only by design: core diagnostics are persisted to the DB, and
MCP output is read by AI clients.

## Implementation status (→ milestones in docs/10)

| | Scope | Status |
|---|---|---|
| M1 Foundation | Schema v1 / meta.json I/O / index rebuild / minimal UI | ✅ |
| M2 Ingest | 4-source metadata resolution / job queue / 6-stage pipeline / duplicate detection (DOI, arXiv, pdf_hash) / local-PDF resolution (convert-first + Crossref bibliographic search) / JobRunner | ✅ |
| M3 AI processing | Worker HTTP API / Docling & bge-m3 engines (lazy load) / chunking | ✅ |
| M4 Search | Hybrid search (FTS5 + KNN + RRF) / search UI (semantic when the worker is up) / PDF viewer | ✅ |
| M5 MCP | paperd-mcp 7 tools (search / bibtex / fulltext / metadata / add_paper / add_note / **apply_fulltext_patches**) / stdio JSON-RPC | ✅ |
| Conversion quality | Mojibake-detection heuristics (conversion_warnings badge) / high-accuracy reconversion (force_ocr + formula_enrichment, reconvert job) / **LLM correction workflow via MCP** (paper.corrected.md overlay + history + automatic reindex → docs/05 §4.1, §5; docs/07 §2.6) | ✅ |
| M6 Periphery | Citation graph (refetch_citations job / stub papers / TTL / ego-network view / stub promotion) / **Markdown tab (conversion review — the text AI actually reads → docs/09 §4)** / notes UI / ingest UI (+ dialog, PDF drop, file/folder picker) / job progress UI / settings (MCP snippet, worker setup) / **favorites & own-paper flags + own-papers citation network (rich view → docs/09 §4.1)** / **worker auto-start + status-bar indicators + MCP onboarding & last-access display (→ docs/07 §6, docs/09 §9)** / **distribution prep: bundled worker + auto-deploy, uv discovery (GUI PATH issue), release.sh (signing/notarization), index-rebuild menu, worker stop on quit, process-level MCP test** | ✅ |

### Known remaining work for v1

- Polishing the first-run setup wizard (currently manual `uv sync` / start from the Settings "Worker" tab)
- Jumping from search hits to the PDF page (provenance approximation → docs/09 §5; jumping to the Markdown tab is implemented)
- Node sizing by citation count in the citation graph (stub rows lack a citationCount column)
- Crossref candidate list in the manual-resolution UI (direct DOI/arXiv ID input is implemented)
- Filter tokens for the paper list (year range, status, venue)
- Parallelizing network-bound jobs in JobRunner (currently fully serial)

### Main deviations from the design docs (implementation decisions)

1. **sqlite-vec → pure-Swift KNN**: the system SQLite cannot load extensions, so
   `vec_chunks` is a plain table (float32 BLOB) and `VectorStore` does brute-force KNN.
   The interface (`rowid = chunks.id`) matches the design doc, so adopting sqlite-vec later
   only requires swapping this type.
2. **No MCP SDK — hand-rolled stdio JSON-RPC from the start** (the minimal configuration
   permitted by docs/07 §1: tools/list and tools/call only).
3. **Chunk token counts are approximate** (max of word count and chars/4), not the bge-m3 tokenizer.
4. **JobRunner job execution is fully serial in v1** (the design doc allows 2–3 parallel network jobs; parallelization is future work).
5. **The collections feature was removed after implementation** (2026-06, see the design-change
   note in docs/02), replaced by favorite/own-paper flags. Existing collection data (tables,
   collections.json) is dropped by migration v3.
6. **Supplementary-PDF confound bug (found and fixed in E2E)**: for short documents without
   their own DOI, the reference list fell inside the ID-extraction window (first 6,000 chars)
   and the document was mis-registered under a cited paper's DOI. Fixed by limiting ID
   extraction to text before the References heading (→ docs/04 §4).
7. **URL ingest failed for anything but ID-bearing URLs (found and fixed in E2E)**:
   `.webpage`/`.directPDFURL` were dead ends in the resolver. Implemented citation_* meta-tag
   resolution and direct PDF download (→ docs/04 §2). Also fixed a stale-payload bug where
   a pdf_url written by resolve was invisible to fetch within the same run (stale Job snapshot).
   Verified to `indexed` with the NeurIPS 2017 Attention paper URL.
8. **MCP server SIGABRT right after the initialize response (found with a real client, fixed)**:
   `synchronizeFile()` (fsync) in the stdio loop throws `NSFileHandleOperationException` on
   pipes and killed the process before tools/list, so no tools were ever registered.
   Single-shot pipe E2Es (one request → one response) never saw the post-response crash, so it
   lurked for a long time. Fixed to fflush only; regression-tested with multi-request sessions.
9. **get_fulltext(section:) returned stale text right after corrections (found in real AI use, fixed)**:
   the section path served chunk-derived text (pending the reindex job), so uncorrected text
   was returned right after apply_fulltext_patches or while the app wasn't running. For papers
   with corrections, switched to heading-based extraction from the effective Markdown (→ docs/07 §2.3).
10. **Load incident from duplicate reindex jobs (found in real AI use, fixed)**: applying MCP
   correction patches in 5 batches queued 5 reindex jobs, and concurrent re-embedding of the
   same paper bogged down the whole machine. Added deduplication that skips enqueueing while
   a queued/running job of the same kind+paper exists (→ docs/04 §7).
11. **Freeze on hub papers in the citation graph (found in E2E, fixed)**: a classic paper with
   1,600+ degree exploded the displayed node count (up to ~80k nodes at 2 hops) and the O(n²)
   layout ran synchronously on the UI thread. Fixed with display caps (150 first-hop, 400 total,
   "+N omitted" badges) and incremental layout (→ docs/08 §6).

### Verified E2E paths (real environment, real APIs)

Verified with a real PDF (a 10-page J. Appl. Phys. 2023 paper), a real worker (Docling + bge-m3), and real APIs (Crossref / S2 / OpenAlex):

- **PDF drop → indexed**: local-PDF resolution (Docling conversion → title extraction → Crossref bibliographic search to pin the DOI → S2/OpenAlex enrichment) → 35 chunks embedded and indexed
- **Citation graph**: automatic refetch_citations on ingest completion → S2 + **OpenAlex supplement merge** (→ docs/08 §1). On a real paper, OpenAlex filled S2's indexing gaps (4/9 incoming citations → the true 9), and 46 references unavailable from the publisher were recovered from referenced_works
- **Search**: English hybrid (FTS5 + semantic) and **cross-lingual semantic search (Japanese query → English papers)**
- **MCP**: `search_papers` (Japanese semantic query) and `get_bibtex` (complete @article entry) via `paperd-mcp`
- **Conversion-correction workflow**: against real mojibake (66 spots where = was garbled to ¼), applied patches via MCP `apply_fulltext_patches` → `paper.corrected.md` created (original untouched, history recorded) → reindex auto-queued → corrected text hits FTS search and the `conversion_warnings` badge updates, end to end
- **High-accuracy reconversion (real Vision OCR)**: all 66 ¼-garbles in the same paper **fully recovered** with `force_ocr` (ocrmac) (x ¼ 0 : 52 → x = 0.52). The side effect of Cyrillic homoglyphs (PbTiO3→РЬТіОз etc., 19 chars) was caught by quality detection and is fixable via MCP corrections
- Headless operation via `paperd-cli` (jobs / papers / add / attach / resolve / reconvert / markdown / delete / retry-failed / process / search)

### Bugs found and fixed via E2E

1. Worker `/embed` ran blocking inside `async def` → all endpoints stalled during the first bge-m3 load (~3 min), and even `/convert`'s 202 response timed out. Fixed with `anyio.to_thread` + regression test
2. Swift URLSession default 60 s timeout was too short for the model cold load → extended to 600 s
3. Lock-file race on worker restart (the old process's delayed shutdown deleted the new process's lock) → unlink now checks pid ownership
4. Docling sometimes emits the paper title as `section_header` instead of `title` → title extraction with heading fallback (`DoclingParser.titleCandidate`)
5. S2's `"data": null` (publisher withholds references) was treated as a parse error → handled as an empty list
6. On PDF drop, a journal running header was mistaken for the title → registered as an unrelated entry that never merged with the same paper already registered by URL (metadata_only) → redesigned the resolution chain (prefer DOI/arXiv IDs printed in the body, demote all-caps headers, validate resolved titles, auto-merge into metadata_only rows, explicit attach via PDF-tab drop → docs/04 §4)
7. Crossref bibliographic search for local PDFs **ranked an SSRN preprint above the published version (Acta Materialia)**, cascading into @misc entries, missing abstracts, S2 404s on citation fetch, and double registration with a citation-graph stub row → prefer near-tied published records (journal-article / proceedings-article) + absorb stubs on post-resolution DOI duplication (→ docs/04 §4)
