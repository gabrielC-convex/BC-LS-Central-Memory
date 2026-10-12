---
name: bcapps-source-repo
description: microsoft/BCApps on GitHub is the readable SOURCE of BC's application layer — the exact gap symbols leave (method bodies); Base Application lives only on main under src/Layers/W1/BaseApp, release branches carry System Application + Business Foundation + first-party apps
tags: [al, symbols, alpackages, extension, version, catalog]
metadata:
  type: reference
provenance: observed
verified: 2026-08-04
---

Symbol packages (`.alpackages/*.app`) never contain method bodies — signatures, fields and
properties only. For Microsoft's own apps there is a way past that wall:
**https://github.com/microsoft/BCApps** (MIT-licensed) holds the actual AL source of the
application layer. When you need to know what a Microsoft procedure *does* — not just that it
exists — read it there instead of guessing from the signature.

## What is where (verified by cloning, 2026-08)

| Branch | Contains | Does NOT contain |
|---|---|---|
| `releases/NN.N` (e.g. `releases/28.2`) | System Application, Business Foundation, first-party apps (Shopify, E-Documents, Excel Reports, Subscription Billing…) under `src/Apps/W1`, dev tools (Test Framework, Performance Toolkit, AI Test Toolkit) under `src/Tools` | **Base Application** |
| `main` | all of the above **plus Base Application** under `src/Layers/W1/BaseApp` (~8,100 .al files) and country layers under `src/Layers/<country>` | — |

So: to read System Application at the tenant's exact version, shallow-clone the matching
release branch. To read **Base Application** bodies you must take `main` — which is vNext, so
treat what you read as "how it works now", not "how it works on my tenant"; posting routines
drift slowly, but verify anything version-sensitive against the tenant.

Release branches exist per minor (`releases/24.0` … `releases/28.4`), so the clone can match
the tenant's application version precisely.

## Cloning without drowning

- Release branch, everything: `git clone --depth 1 --branch releases/28.2 …` (~165 MB).
- `main` for BaseApp only — sparse, or the country layers multiply the download:
  ```
  git clone --filter=blob:none --no-checkout --depth 1 --branch main <url> BCApps-main
  git -C BCApps-main sparse-checkout init --cone
  git -C BCApps-main sparse-checkout set "src/Layers/W1/BaseApp" "tools" "docs"
  git -C BCApps-main checkout main
  ```
  (~230 MB with BaseApp.)
- ⚠️ Do **not** clone into an AL workspace — the AL extension picks up the thousands of `.al`
  files and compilation breaks. Clone next to the project, not inside it.

## What is NOT there, ever

The platform: server (NST), the `alc` compiler, the web client. And nothing third-party —
ISV apps (LS Central, vertical solutions) stay closed; for those, symbols + live data remain
the only sources. See [[symbolreference-json-trailing-padding]] for reading symbols.

## Bonus for Claude Code users

`tools/al-docs-plugin` (main only) is a Claude Code plugin written by the BC Application Team:
a `/al-docs` skill that bootstraps/updates/audits hierarchical documentation (CLAUDE.md,
data-model.md, business-logic.md, patterns.md) for any AL codebase — usable on your own
extension, not just on BCApps.
