---
name: paperd-research
description: DeepResearch-style literature survey across the paperd library and the web. Decomposes a topic, runs library search and web research in parallel, adds important missing papers to the library with user approval, and saves survey notes. Use for requests like "survey the literature on ...", "do a literature review", or "find related work" (users may phrase these in any language).
version: 2
---

# paperd Literature Survey Workflow

Combine the paperd MCP server (search_papers / get_fulltext / get_paper_metadata / get_citations / add_paper / add_note / get_bibtex)
with web search to conduct a literature survey centered on the user's library.

## Steps

1. **Decompose the topic**: Break the survey topic into 2-4 subtopics. If the topic is ambiguous, ask exactly one clarifying question first.
2. **Search the library first**: Run `search_papers` for each subtopic to map out what the user already has.
   The search is semantic, so queries in any language can match English papers. For important hits, inspect
   their content with `get_fulltext` (preferably with a section specified).
3. **Follow the citation graph**: For pivotal library hits, call `get_citations` to traverse references
   (works they cite) and citations (works that cite them). This surfaces related work the user already owns
   (`in_library: true`) and important missing papers. If the result `status` is `fetching`, the app is
   retrieving the graph in the background — continue and retry shortly.
4. **Run web research in parallel**: Launch sub-agents (Task) in parallel, one per subtopic, to collect
   recent developments and key papers (title, authors, year, DOI / arXiv ID, abstract).
5. **Cross-check against the library**: For each paper found on the web, check whether it is already in the
   library via `search_papers` (search by title), and build a list of papers not yet owned.
6. **Propose additions (important: never add without approval)**: Present the top missing papers
   (roughly 3-10) to the user with reasons, and add **only the approved ones** with `add_paper`
   (prefer doi / arxiv_id). PDF download, conversion, and indexing proceed asynchronously on the app side.
7. **Save survey notes**: Compile a summary of the survey (findings per subtopic, key reference list,
   open questions) and, if there is a central paper, save it to that paper's notes with `add_note`
   (if no suitable target exists, chat output alone is fine).

## Rules

- Additions to the library always require the user's approval (the library is the user's asset; do not pollute it)
- When citations are needed, use `get_bibtex` (do not hand-write them)
- When citing or summarizing papers in the library, base it on `get_fulltext` content (do not speculate about their contents)
