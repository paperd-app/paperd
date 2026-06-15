# Development

Developer-facing notes for building, testing, and hacking on paperd. For what the app
is and how to install it, see the [README](README.md). Design docs live in
[docs/](docs/00-overview.md) (Japanese) and are the source of truth alongside the code —
keep them current (see [CLAUDE.md](CLAUDE.md)).

## Repo layout

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
  PaperdMCPKit/           # MCP server logic (hand-rolled stdio JSON-RPC + 8 tools → docs/07)
  PaperdMCP/              # paperd-mcp CLI
  Paperd/                 # SwiftUI app (3-pane UI, search, citation graph, settings)
Tests/PaperdTests/        # Swift tests (Swift Testing)
worker/                   # Python worker (FastAPI / Docling / bge-m3 → docs/05)
skills/                   # Bundled Claude skills (installable from Settings → ~/.claude/skills)
agents/                   # Bundled Claude subagents for research orchestration (installable → ~/.claude/agents, → docs/12)
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

## MCP server (development)

For a development build, register the locally built `paperd-mcp` binary. (Installed users
copy a ready-made snippet/command from the app's Settings → see [README](README.md) and docs/07 §6.)

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

## Releasing

paperd ships as a notarized Developer ID `.app` via a Homebrew cask. The release flow
(`scripts/release.sh` → tag → `gh release` → tap update) is documented separately.
```

