---
name: pte-permissionset-tabledata
description: Every custom table needs an explicit tabledata entry in the extension's permission set or a PTE install fails on Production with PTE0004 — sandboxes never validate this, so it first appears on the environment you least want it on
tags: [pte, saas, permissionset, publish, extension, pte0004, error-message, misleading, troubleshooting]
metadata:
  type: reference
provenance: observed
verified: 2026-07-31
---

A per-tenant extension that installs fine on every sandbox can fail its first Production install
with **PTE0004** because a `table` object it declares has no matching `tabledata` permission in
the extension's permission set:

```al
permissionset <id> "..."
{
    Assignable = true;
    Permissions =
        tabledata "My Buffer Table" = RIMD,
        tabledata "My Setup Table"  = RIMD;
}
```

Three things make this expensive to diagnose:

- **Sandboxes do not validate it.** The same package installs cleanly on Dev/UAT/PreProd and
  fails only on a Production-type environment.
- **The error text is UI-only.** It is shown on the *Extension Installation Status* page. The
  automation API and the deployment cmdlet report a generic failure, so a scripted deploy shows
  "failed" with no cause.
- **It is per table object, not per app.** Adding a single new `table` months into a project
  re-arms it, and nothing in the build warns you.

`tableextension` fields and FlowFields need **no** entry — PTE0004 is about `table` objects only.

**Why:** the failure lands on the first Production deployment, which is usually the moment with
the least time and the most people watching, and the message you get from automation does not
name the missing permission.

**How to apply:** make it a rule that creating a `table` object and adding its `tabledata` line
are the same edit. Before a first Production install, diff the list of `table` objects in the
app against the `tabledata` lines in the permission set — it is a two-minute check that removes
an entire class of deployment failure.
