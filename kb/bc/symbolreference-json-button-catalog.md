---
name: symbolreference-json-button-catalog
description: Every BC symbol .app contains SymbolReference.json with the full page/action tree — names, captions, RunObject targets — so a "what buttons does page X have" catalog is generatable offline, no tenant, no source code
tags: [symbols, SymbolReference, alpackages, pages, actions, buttons, catalog, RunObject, caption, tooltip, metadata]
metadata:
  type: reference
provenance: observed
verified: 2026-07-30
---

A BC symbol package (`.app` from `.alpackages`) is a ZIP behind a 40-byte header, containing
only 4 entries: `NavxManifest.xml`, **`SymbolReference.json`**, `DocComments.xml`,
`[Content_Types].xml`. The JSON holds the complete object metadata of the app.

**Verified on LS Central 28 symbols** (4.5 MB .app → 42.6 MB JSON, parsed by Python in 0.9 s):

- top-level arrays per object type: `Tables`, `Pages`, `Codeunits`, `Reports`, `PageExtensions`,
  `EnumTypes`, `Interfaces`, … (2,878 pages, 1,848 codeunits, 1,799 tables in LS Central alone)
- pages carry an **`Actions` tree** (nested groups — recurse to flatten): 1,515 pages with
  actions, ~20,000 actions total
- each action has `Name`, `Kind`, and `Properties` including **`Caption`**, **`ToolTip`**,
  **`RunObject`**, `Image`, `ApplicationArea`, `ShortCutKey`, `Enabled`,
  `AccessByPermission`, `ObsoleteState`
- **`RunObject` is the gold**: for navigation actions it says exactly which page/report the
  button opens — "what does this button do" answered automatically for that whole class
- newer BC apps (24+) may nest collections under `Namespaces` — walk recursively

**Limits, equally verified:** `ToolTip` is frequently empty in ISV symbols (all 226 actions of
one large LSC list page had none). Action **code** (`OnAction` triggers, business logic) is NOT
in symbols — that needs source. So the catalog answers "what buttons exist and where do they
lead", not "what does the trigger code compute".

**Why:** a page→buttons→targets catalog for thousands of pages would take months by hand and
goes stale; from symbols it regenerates in seconds, offline, with zero tenant access — and it
turns "which button on which page opens X?" into a sub-second local query instead of a
token-expensive exploration.

**How to apply:** read the `.app`, seek to `PK\x03\x04` (offset 40), open as ZIP, parse
`SymbolReference.json` with `utf-8-sig`. Flatten `Actions` recursively (groups contain
actions). Properties are a `[{Name, Value}]` list — index them into a dict. Cache the parse
(SQLite/pickle) if querying repeatedly. See also [[public-symbol-nuget-feeds]] for getting
symbols without a tenant.
