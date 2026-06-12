---
name: paperd-cite
description: Find supporting references in the paperd library for a manuscript in progress and produce citations. Use for requests like "add citations to this paragraph", "find papers in my library that support this claim", or "build the reference list" (users may phrase these in any language).
version: 1
---

# paperd Writing Citation Workflow

For the user's manuscript (paragraphs, claims, bullet points), find supporting evidence in the library's papers and prepare the citations.

## Steps

1. Break the manuscript down into individual claims.
2. For each claim, search the library with `search_papers` (using both a paraphrase of the claim and keywords).
3. For candidate papers, check the relevant passages with `get_fulltext` (with a section specified) and verify
   that they **actually support the claim**. Do not judge from the abstract alone. If a paper does not support
   the claim, report honestly that no supporting evidence exists in the library.
4. Citation output:
   - For LaTeX manuscripts, fetch entries with `get_bibtex` and present the text with `\cite{key}` inserted at the claim's position
   - Otherwise, insert author-year citations (e.g. (Vaswani et al., 2017)) and append a reference list at the end
5. For claims with no suitable reference in the library, state this explicitly (if searching the web for papers,
   follow the paperd-research skill's rules for adding them).

## Rules

- Every citation must be verified against the full text (never cite just because "the title looks right")
- Use `get_bibtex` output as-is for BibTeX (do not invent keys or fields)
