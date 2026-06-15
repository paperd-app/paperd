---
name: paperd-fix-conversion
description: Fix PDF-to-Markdown conversion errors (garbled characters, broken formulas, misrecognition) in paperd library papers by cross-checking against the original PDF. Use for requests like "fix the conversion errors" or "fix the garbled Markdown" (users may phrase these in any language).
version: 2
---

# paperd Conversion-Fix Workflow

Safely fix conversion errors in a paper's Markdown using paperd MCP's `paperd:apply_fulltext_patches`.

## Steps

1. Get the target paper's `pdf_path` / `markdown_path` / `conversion_warnings` with `paperd:get_paper_metadata`.
2. Read the Markdown with `paperd:get_fulltext` and list suspicious passages. Typical cases:
   - Garbled characters: `¼` `½` (misrecognized ≈ or formulas), `(cid:123)`, stray Cyrillic characters (РЬТіОз ← PbTiO3)
   - Missing superscripts/subscripts: `10^3 Å` → `103 Å`
   - Broken formulas and chemical formulas
3. **Always read the original PDF at `pdf_path` and cross-check.** Never write content that is not in the
   original (this is the most important rule).
4. Build the patches. Cut each `find` string long enough that it **occurs exactly once in the current text**
   (too short and it errors with multiple matches; include surrounding context to make it unique).
5. Apply with `paperd:apply_fulltext_patches`. In `note`, record the justification for the fix (the relevant PDF page and location).
6. Verify after applying with `paperd:get_fulltext` (fixes are reflected immediately in the effective Markdown,
   including section-scoped reads). Only `paperd:search_papers` snippets lag until the search index is rebuilt
   (the app runs this in the background). The fix history is kept on the app side and the user can revert it.

## Rules

- Do not make "plausible-looking" fixes without cross-checking against the original PDF
- Prioritize passages where the meaning is broken over bulk mechanical replacements (the kinds of `conversion_warnings` are a clue)
