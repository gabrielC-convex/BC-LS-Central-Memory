---
name: autonomy-on-ls-central-needs-a-verify-loop-before-docs
description: An AL change on BC / LS Central is only as good as the loop that verifies it — compile (alc + exact symbols), run (a sandbox where the extension is published and AL tests execute), project knowledge, and only then vendor documentation; never report a change as done without "compiled: yes / tests: n passed"
tags: [verification, al, symbols, alpackages, sandbox, testing, no-docker, documentation]
metadata:
  type: reference
provenance: observed
verified: 2026-10-12
---

Proposed on 2026-10-10 by the assistant instance working on the owner's other (non-BC)
project, as an outside observation; adapted on 2026-10-12 by the instance working in the BC
workspace, which checked each claim against what the workspace really has. The owner's goal:
most of a task done without a human in the loop.

## Why does an AL solution fail or come out convoluted?

Rarely because of a general knowledge gap about LS Central. It fails because of a
**verification gap**: AL proposed without being compiled and run is a guess, and the second
answer after a failure report is guessed as much as the first. Documentation does not close a
verification gap; a loop does.

## What closes the gap, in priority order

1. **Compile locally.** The AL compiler (`alc.exe` from the AL Language extension, headless)
   plus the symbol packages of the exact Base Application, System Application, LS Central and
   localisation versions in `.alpackages/`. This removes the class "solution that does not
   compile". The symbols are also the complete, legitimate list of tables, fields, procedures
   and published events an extension may hook — query them with `python tools/al.py`
   (`page|table|object|find|whoruns|events`) instead of inventing object names.
2. **Run it.** A sandbox where the extension is published and AL test codeunits execute, and
   where the result can be read back (API pages, telemetry). This is the difference between
   "should work" and "tested".
3. **The project's own knowledge**: exact versions, what is customised and where, decisions
   taken, what failed and why, the owner's retail vocabulary.
4. **Vendor help and training**, searched on demand — see
   [[docs-library-is-retrieval-not-memory]]. They say what a retail flow must DO, so that
   requirements are read correctly; alone they close a small part of the gap.
5. **Vendor source**, only where the owner is entitled to it. Second best: runtime traces
   (event subscribers that log the order of calls) run in the sandbox of step 2.

## What the BC workspace already has (checked 2026-10-12)

- Step 1 exists: a compile script drives `alc` against `.alpackages/`; `tools/al.py` answers
  symbol questions offline in milliseconds.
- Step 2 exists in a SaaS form, not a container: Docker is not available on the workstation,
  so there is no local BC container. The extension is published to SaaS sandbox environments
  and AL tests run there through `altool runtests` over the dev endpoint. Diagnostic API pages
  and Application Insights telemetry are readable from scripts.
- The limits are real and must be stated per task: publishing needs the owner's token and, for
  anything beyond a sandbox, his explicit request; a sandbox never drives real fiscal or
  payment hardware, so POS hardware paths cannot be verified end to end.
- Step 3 exists (this kb plus the workspace's own memory). Step 4 is not built yet.

**Why:** with documentation but no loop the assistant stays a consultant who guesses nicely;
with a loop but no documentation it still reaches the answer, more slowly; with both, a high
unattended success rate is realistic.

**How to apply:** every task report states, in these words, `compiled: yes/no` and
`tests: n passed / not run (why)`. A change that could not be run says so and names what would
verify it. See [[two-claude-instances-share-the-repo-kb-not-private-memory]] for how this kb
and each instance's private memory stay apart.
