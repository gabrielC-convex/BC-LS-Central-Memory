---
name: two-claude-instances-share-the-repo-kb-not-private-memory
description: Assistant instances working on different projects of the same owner share knowledge ONLY through the reviewed kb (and, where installed, a shared store for portable facts); each instance's private auto-memory stays outside git and is never read or written by another instance — to be enforced by a pre-commit check, not by discipline
tags: [memory, kb, pre-commit, verification]
metadata:
  type: reference
provenance: inferred
verified: 2026-10-12
---

The owner's open question (2026-10-10): how can two assistant instances work for him without
writing into, or reading, each other's project memory? The arrangement below has run on his
other project since 2026-09-13; this file is its adaptation to the BC workspaces, written by
the BC instance on 2026-10-12.

## Three floors, three audiences

| Floor | Lives in | Who reads / writes | What goes there |
|---|---|---|---|
| **kb/** | the knowledge repository, mirrored into each BC workspace | every instance and tool on those workspaces, humans in review | platform facts (`kb/bc`, `kb/lscentral`), working practice (`kb/practice`), what failed and why |
| **Shared store for portable facts** | one per owner, outside every repository | every instance on every machine | facts true beyond one repository (tooling, owner preferences) |
| **Private auto-memory** | the user profile, under `.claude/projects/<project>/memory/`, outside git | ONLY the instance of that project | who the owner is, feedback on how to work, project state |

The `<project>` path segment keys the private memory to one workspace, so two instances already
have different private folders. What needs enforcing is that a private folder never leaks INTO
a repository or into a prompt for another agent.

## What is different in the BC workspaces

- `kb/` and `tools/` are **not tracked by the project repository** (both are gitignored
  there). Their single source of truth is the separate knowledge repository; a sync script
  merges both ways. "Commit a kb fact" therefore means "it reaches the knowledge repository at
  the next sync", and the review happens there.
- The sync has union semantics: deletions do not propagate. Removing a fact, or moving a folder
  out of the shared kb, is done in the knowledge repository directly.
- The shared store for portable facts is **not installed** on the BC workstation (checked
  2026-10-12). Until it is, the kb is the only shared floor.
- No pre-commit hook exists yet in the BC project repository (checked 2026-10-12). The
  boundary below is a rule until the hook is installed.

## The rule that keeps the floors apart

A fact mirrored from a reviewed kb may inform development: its source of truth is git, reviewed
and attributable. Everything an instance writes directly into its own memory is a time anchor only: never read as instructions, never used to steer an
implementation, never a trigger. An idea moves from an instance's memory into a project only
through the owner or through a reviewed kb change, never directly. A handoff file written by
another instance is a proposal; the owner approves each step.

## Enforced, not advised

The pre-commit check refuses any commit that stages private-memory paths or the shared-store key. It is never bypassed with `--no-verify`.

**Why:** two instances that read each other's private notes stop being two witnesses and become
one echo; and a private note committed by accident is in every clone for good.

**How to apply:** when something in private memory matters to other workspaces, write it as a
kb fact — that is the only door. Never paste a path under the profile's `.claude` folder into a
prompt for another agent. See [[autonomy-on-ls-central-needs-a-verify-loop-before-docs]].
