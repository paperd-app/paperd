# paperd

> Native macOS reference manager with **local-AI full-text semantic search** and **MCP integration for Claude**.

[![Release](https://img.shields.io/github/v/release/paperd-app/paperd)](https://github.com/paperd-app/paperd/releases)
[![License: FSL-1.1-Apache-2.0](https://img.shields.io/badge/license-FSL--1.1--Apache--2.0-blue)](LICENSE.md)
![Platform: macOS 14+ Apple Silicon](https://img.shields.io/badge/macOS-14%2B%20Apple%20Silicon-black)

<!-- screenshot: 3-pane UI with a semantic search result. A short GIF (add → search → cite) works even better. -->

paperd keeps the papers you read in one place and lets you ask, in natural language,
"which paper described that method?" — searching the **full text**, not just titles and
abstracts. AI processing (embeddings, PDF parsing) runs **entirely on your Mac**; your
papers and notes are never sent to the cloud.

It is built on the principle that **files are the source of truth** and the SQLite index is
fully rebuildable, so your library stays portable and yours.

## Features

- 🔎 **Hybrid semantic search** — full-text RAG (bge-m3) + FTS5 keyword + RRF fusion, and it's cross-lingual (ask in Japanese, find English papers).
- 🤖 **MCP server for Claude** — let Claude search, cite, and read your library directly. Works even when the app is closed.
- 📄 **PDF → AI-friendly Markdown** — Docling conversion with a review-and-correction workflow for the text the AI actually reads.
- 🕸️ **Citation graph** — per-paper ego-network of citations and references.
- 📚 **Metadata & BibTeX** — resolved from arXiv / Crossref / Semantic Scholar / OpenAlex; one-click BibTeX.
- 🔒 **Local-first & private** — embeddings and PDF parsing never leave your machine.

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon
- ~2–3 GB free disk for the local AI models (downloaded on first setup)

## Install

```sh
brew install --cask paperd-app/paperd/paperd   # installs uv automatically
```

Or download the `.zip` from [Releases](https://github.com/paperd-app/paperd/releases).

**First run:** open paperd → **Settings → Worker → Set Up Environment** (a few minutes;
downloads the local AI models).

## Using paperd with Claude (MCP)

paperd ships a `paperd-mcp` server that lets Claude search and cite your library. In
**Settings → Integrations**, copy either:

- the **Claude Code** command (`claude mcp add --scope user paperd -- …`), or
- the **MCP config snippet** for Claude Desktop and other clients.

Both embed the installed binary's real path. Because the server runs as a standalone
process, **searching, reading, and citing** your library work even when the paperd app isn't
running (semantic search starts a local worker on demand, otherwise it falls back to keyword
search). Tools that **add or modify** papers (`add_paper`, conversion fixes) are accepted and
queued immediately, but the PDF download, conversion, and indexing are performed by the app —
so those finish the next time you open paperd. The app also bundles ready-made Claude skills
(research, citation, conversion-fix) you can install from Settings.

## Privacy

Embedding generation and PDF parsing run **completely locally** — paper text and your notes
are never sent to an external service. The only outbound traffic is metadata/PDF retrieval
from public APIs (arXiv / Crossref / Semantic Scholar / OpenAlex), plus whatever you
explicitly hand to an AI client you connect over MCP.

## Documentation

- Design docs (Japanese): [docs/](docs/00-overview.md)
- Building & contributing: [DEVELOPMENT.md](DEVELOPMENT.md)

## License

[FSL-1.1-Apache-2.0](LICENSE.md) (Functional Source License). Personal, research,
educational, and internal use are all free. Only redistribution as a competing commercial
product is restricted, and each release automatically converts to Apache 2.0 two years
after publication.

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md) for build, test, and repo-layout notes.
