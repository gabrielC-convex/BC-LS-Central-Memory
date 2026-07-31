---
name: symbolreference-json-trailing-padding
description: Some publishers pad SymbolReference.json after the closing brace, so json.loads() dies with "Extra data" — a naive parser reports the package as having no symbols at all instead of reporting a parse error
tags: [symbols, symbolreference, alpackages, parsing, troubleshooting, misleading, silent-failure]
metadata:
  type: reference
provenance: observed
verified: 2026-07-31
---

`SymbolReference.json` inside a `.app` is not always exactly one JSON value. Several publishers
append padding bytes after the closing brace, so the standard parse fails:

```
json.decoder.JSONDecodeError: Extra data: line 1 column 213592 (char 213591)
```

The payload before that offset is complete and valid — only the tail is junk. Stop at the end of
the first value instead of demanding that the whole string be consumed:

```python
text = zf.read(name).decode("utf-8-sig")     # BOM is also present
obj, _ = json.JSONDecoder().raw_decode(text) # NOT json.loads()
```

**Verified 2026-07-31** on a `.alpackages` set of 13 packages: all Microsoft and LS Central
packages parse with plain `json.loads`; **every** Intelligent Systems package (Hardware App,
Romanian Fiscalization, Romanian Localization, RO Loc for LS Central, AppSource Licensing) needs
`raw_decode`. Switching to `raw_decode` took one indexer from 25,470 to 26,312 objects and from
134,602 to 137,307 methods — the entire third-party layer had been invisible.

Two smaller traps in the same function: the entry is not guaranteed to sit at the archive root,
so resolve it by basename (case-insensitively) rather than opening `"SymbolReference.json"`
literally; and the zip itself starts at the `PK\x03\x04` magic behind a 40-byte header
(see [[symbolreference-json-button-catalog]]).

**Why:** the usual `except json.JSONDecodeError: return None` turns a parse bug into "this package
has no symbols", which reads like a property of the vendor's package rather than a bug in the
reader. Nothing errors, nothing is logged as wrong, and the packages you most need — the ISV ones
whose source you do not have — are exactly the ones that disappear.

**How to apply:** in any symbol reader, use `raw_decode`, and make the failure message
distinguish "no SymbolReference entry in the archive" from "entry found but failed to parse".
If an ISV package shows zero objects, suspect the reader before suspecting the package.
