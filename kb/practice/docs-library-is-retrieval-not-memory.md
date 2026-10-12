---
name: docs-library-is-retrieval-not-memory
description: Vendor documentation (LS Central help and its release-notes page) belongs in a separate retrieval library queried on demand — never in kb or in private memory; hybrid keyword + semantic search, version is a label and a ranking hint but NEVER a filter; Business Central docs are asked live through the public Microsoft Learn MCP and are not indexed
tags: [documentation, retrieval, mcp, kb, memory]
metadata:
  type: reference
provenance: inferred
verified: 2026-10-12
---

Owner's goal (2026-10-12): the assistant should have the LS Central documentation at hand
without its memory growing too large to use. Decision: a LIBRARY, not memory. Nothing is loaded
into context; the assistant asks a question and gets back a few passages with their source.
Status on 2026-10-12: a design agreed with the owner, **not built yet**.

## Three stores, never mixed

| Store | Holds | Refresh |
|---|---|---|
| shared library | LS Central help + the page announcing new versions and bug fixes | monthly at most |
| per-client library | one client's documents and code, own index, deletable on request | per engagement |
| kb | what WE learned doing tasks — traps, patterns, decisions | per task |

A lesson learned at a client enters the kb only as a general, anonymised lesson, never as a
detail of that client.

## Which source answers which question?

- **Structure of a standard object** (fields, actions, events): `python tools/al.py`, live from
  the symbol packages. Not documentation, not the library.
- **Business Central behaviour**: the public Microsoft Learn MCP server, asked live. It is
  always current and it does not cover LS Central or the localisation apps. Not indexed.
- **What an LS Central retail flow is meant to do**: the library.
- **What we learned the hard way**: `python tools/kb.py search`.

## Design decisions already taken with the owner

- **LS Central help is not versioned consistently.** Version is stored as metadata, used to
  rank (target version first, then the nearest older one) and to label every passage — it is
  NEVER a filter. Not found on the target version means: answer from an older one and say so.
- **Index the release-notes / bug-fix page too**, tagged separately: it is the only source
  that says what changed between versions.
- **Hybrid search.** Keyword search for exact identifiers (table names, codeunit numbers, field
  names, error text) plus semantic search for questions phrased differently from the docs.
  Semantic-only loses the identifiers.
- **Local first, hosted later, no rewrite:** one service with a fixed interface (MCP), the
  index in a single file (SQLite FTS5 plus vectors, like the `tools/kb.py` index), embeddings
  computed locally.
- **The service returns raw passages and paths**, with no small model in between: a summariser
  can drop the one field name that mattered.
- **A separate, labelled collection for vendor source**, if and only if the owner confirms he
  is entitled to it. Every answer says whether a claim comes from source or from help.
- **Measure it:** 20–30 real questions from past tasks with a known answer; check that the
  right passage is retrieved before trusting the library.
- Check the content licence before exporting any help site; keep the export outside git.

**Why:** a library that is searched costs nothing in context however large it grows;
documentation pasted into memory makes every session slower and the project's own facts harder
to find.

**How to apply:** build it after the verify loop — see
[[autonomy-on-ls-central-needs-a-verify-loop-before-docs]]. It tells the assistant what a
retail flow must DO, not how the vendor's code behaves.
