---
name: run-al-tests-saas-without-docker
description: AL test codeunits can be compiled and run against a BC SaaS sandbox with no Docker at all — the compiler comes from the VS Code AL extension, and the only real obstacle is that the compile endpoint wants a different OAuth scope than the rest of the tooling
tags: [testing, test-runner, no-docker, saas, sandbox, bccontainerhelper, al, publish]
metadata:
  type: reference
provenance: observed
verified: 2026-08-04
---

The usual advice for running AL tests is a container, which needs Docker, which many corporate
machines do not allow. It is not required. A SaaS sandbox can compile, publish and run a test
app end to end.

## The three pieces

**Compiler.** `Compile-AppInBcContainer`-style helpers accept a `-compilerFolder`. Point it at
the compiler that already ships inside the **VS Code AL extension** rather than downloading
multi-gigabyte artifacts. Nothing containerised is involved; it is just `alc.exe` and its DLLs.

**Publish.** The ordinary per-tenant-extension publish path works for a test app exactly as it
does for a production app. Keep the test app as a **separate app** with its own id and its own
`app.json` that depends on the app under test — never ship test codeunits inside the production
extension.

**Run.** The platform test runner on the sandbox executes the codeunits and returns results.

## The trap that costs an afternoon

The `/cs` (compile-and-sync) dev endpoint **returns 401 with the token the rest of the tooling
uses.** It is not an expired token and not a permissions problem on the environment — that
endpoint wants the scope `https://projectmadeira.com/`, while the general BC API calls use
`https://api.businesscentral.dynamics.com/user_impersonation`. Acquire a token for the right
scope for that call specifically.

## Two smaller ones, found the same way

- **`Commit()` does not survive every test runner codeunit** — and the mechanism is now known
  from the runner's source (BCApps, `src/Tools/Test Framework`): isolation is not implemented
  in AL at all, it is the **platform property `TestIsolation` on the runner codeunit**.
  Codeunit **130450** "Test Runner - Isol. Codeunit" (`TestIsolation = Codeunit`, the default)
  rolls back everything a test writes, commits included; codeunit **130451**
  "Test Runner - Isol. Disabled" lets commits land for real. Test *results* survive under
  130450 only because the runner's own triggers execute outside the isolation scope and commit
  explicitly. So: state that must cross a test boundary requires running under 130451 —
  no amount of `Commit()` inside the test helps under 130450.
- **`Init()` does not reset the primary key**, so a table used as a scratch buffer keeps the key
  of the previous record unless it is cleared explicitly. Removing `AutoIncrement` from such a
  table later requires publishing with a **forced** schema sync, which is destructive — decide
  the key design before the first publish, not after.

## Do the Microsoft test libraries have to be installed?

No, and often they should not be. `Test Runner`, `Library Assert`, `Any` and
`Library Variable Storage` are frequently present on sandboxes but **absent on production**
tenants. An `app.json` dependency on them makes the test app impossible to install where they
are missing. Hand-written assertions in a small local codeunit remove the dependency entirely
and cost very little.

**Why this is worth writing down:** the belief that AL tests need Docker leads teams to skip
automated testing altogether on locked-down machines. The actual blocker is one OAuth scope.
