# kb/ — Business Central / LS Central knowledge base

A project within the project, designed to become a **standalone project** at any moment:
copy the `kb/` folder together with `tools/kb.py` into another project and everything works,
no changes needed.

**Language: English.** All knowledge files are written in English — BC/AL terminology is English
anyway, and the knowledge base must be portable across projects and teams.

## The separation contract

| Folder | Contains | Purity rule |
|---|---|---|
| `kb/bc/` | Business Central **default**: platform, Base App, behaviors, traps, decoded error messages | **ZERO** mentions of any client, tenant, environment or project |
| `kb/lscentral/` | LS Central **default**: LSC objects, POS, retail, standard flows | same — ZERO client specifics |
| `kb/client/lensa/` | Things built or learned **specifically for Lensa** | anything; delete the whole folder to keep only default knowledge |
| `kb/practice/` | **How we work**: the verify loop, how knowledge and memory are kept apart, where documentation is looked up | no client specifics; not a platform fact, so kept out of `bc` / `lscentral` |

**Why:** the goal is for `kb/bc` + `kb/lscentral` to grow from project to project, until new
development starts from accumulated knowledge instead of exploration — fast, cheap, minimal
token consumption. The client part is detachable by construction: extraction = copy `kb/bc`,
`kb/lscentral` and `tools/kb.py`, or delete `kb/client/`.

**What does NOT live here:** the working memory of the current project (`.claude/memory/` —
environment, tenant, tokens, project decisions; kept in Romanian, local) and the deliverables
(`docs/`). Those belong to the project.

## The format of a fact

One fact = one file, with frontmatter. `tags` is **mandatory** — it is search fuel and carries
extra ranking weight. Put synonyms and alternative spellings there (e.g. both `awb` and
`shipping-label`), because that is what makes a search hit even when the body uses other words.

```markdown
---
name: stable-kebab-case-name
description: the conclusion, not the topic — the only thing read when deciding relevance
tags: [object-id, tenant, collision, idranges, per-type]
metadata:
  type: reference
provenance: observed
verified: 2026-07-30
---

The fact, with its evidence.

**Why:** why it matters / what it costs you not to know it.
**How to apply:** how to use it concretely. Link related facts with [[name]].
```

- **`tags`** — only values from [taxonomy.yml](taxonomy.yml). Want a new tag? Add it there
  first. This is what prevents `pos` / `POS` / `point-of-sale` becoming three tags.
- **`provenance`** — `observed` (saw the behavior run) | `inferred` (deduced, not executed) |
  `vendor-docs` (read it in official docs). An agent that quotes fast must also know whether
  it *saw* the behavior or guessed it.

Files inside `kb/client/<client>/` get their scope from the folder path — no extra field needed.

## Writing discipline

- **The index is chunk-level**: every `## heading` is a separately retrievable unit. Write
  sections **atomic and self-contained** — no pronouns pointing at the previous paragraph,
  because a retrieved chunk arrives without its neighbours.
- **Write headings as the questions people ask** ("when does Costing Method become locked?")
  rather than as labels ("costing") — it feeds the ranking directly.
- **One fact, one home file.** Everywhere else links with `[[name]]`. Duplicates drift, and
  the search ends up quoting the stale copy.
- **Object documentation gets deterministic paths**: knowledge hanging off a single object
  lives at `kb/<scope>/objects/<type>/<id>-<slug>.md` (e.g.
  `kb/lscentral/objects/page/99001452-lsc-retail-item-list.md`). "I learned something about
  page X" resolves to exactly one path — no "did I already document this?" search. For raw
  structure (fields, buttons) don't write files at all — `tools/al.py` answers live from
  symbols; document only the *learned* layer: behavior, gotchas, why a flow breaks.
- **Process documentation is grouped by business capability**, not by artifact type:
  `kb/<scope>/processes/<domain>/<process>.md` (e.g.
  `kb/lscentral/processes/inventory/transfer-order-two-step-posting.md`). Cross-module chains
  (order → shipment → invoice → ledger) are written as explicit flow files — a flow spelled
  out beats a graph database inferring it.

## The catalog

`python tools/kb.py catalog` regenerates [catalog.md](catalog.md) — one line per fact
(name, description, tags). Small enough to read whole at session start; you then *know what
exists* and search only when you need the body. Never edit it by hand.

## Searching

```powershell
python tools/kb.py search "object id uniqueness" --scope default   # bc + lscentral only
python tools/kb.py refs "page 99001452" --scope lscentral
python tools/kb.py related "/api/Order"      # 2-hop co-occurrence: what shares context with X
python tools/kb.py check                                           # purity + hygiene of default folders
```

`related` is a deliberately cheap graph query: co-occurrence, not causality. It answers
"what lives around X" for discovery; the causal "what breaks if I change X" comes from
`al.py whoruns`/`events` (standard objects) and from the code itself (own extension).

`check` scans `kb/bc` and `kb/lscentral` for client markers (names, tenants, GUIDs, project
object ranges) and for missing `tags`/`description`, and fails if it finds any — run it before
considering the kb "clean".

## Provenance

A default fact may be *discovered* in a client project — write the evidence anonymized
("verified on a live tenant, July 2026"), never with the client's name. If the evidence cannot
be anonymized, the fact is not default — it goes to `kb/client/`.
