---
name: object-id-uniqueness
description: AL object IDs are unique per TYPE, not globally — but the idRanges reservation is per TENANT, so collisions with other installed extensions surface only at publish, never at compile
tags: [object-id, idRanges, tenant, collision, per-type, publish, AL, extension]
metadata:
  type: reference
provenance: observed
verified: 2026-07-30
---

The real uniqueness rule, confirmed on published and working code:

- **Uniqueness is per object type, not global.** The same number can be reused once for every
  AL object type. A `table` and a `tableextension` coexist on the same number; so do a
  `pageextension` and a `report`.
- **The uniqueness domain is the tenant, not the app.** The number must be free for that type
  across *all* installed extensions, plus Base App and any ISV apps. `idRanges` in `app.json`
  is effectively a tenant-level reservation.

**Evidence:** verified on a live cloud tenant (July 2026) — one published, functional PTE uses
the same ID for five objects of different types simultaneously, including a tableextension and
a pageextension declared in the *same* .al file. If the rule were global, alc.exe would fail
the build with a duplicate-ID error; it does not.

Extension pairs proven directly: table/tableextension. Inferred by symmetry (high confidence,
no direct proof): page/pageextension, report/reportextension, enum/enumextension.

**Why:** it determines how many IDs you really have. With a 50-number range and ~14 object
types, the real space is much larger than it looks — but a collision with another extension on
the same tenant is invisible at compile time and only fails at publish/install.

**How to apply:** before allocating a new ID, inventory what is used per type across *all*
projects that target the same tenant — a registry generator script beats memory. Compare only
within the same object type.
