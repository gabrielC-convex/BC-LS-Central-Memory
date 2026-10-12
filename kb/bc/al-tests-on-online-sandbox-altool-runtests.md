---
name: al-tests-on-online-sandbox-altool-runtests
description: On Business Central online sandboxes (28.x) the Microsoft "Test Runner" app cannot be (re)published - the service refuses Microsoft-published extensions in the tenant scope - so any test route built on page 130455 "Command Line Test Tool" (BcContainerHelper connectFromHost) is dead after the first platform upgrade; the replacement is the developer-endpoint test run of AL extension 18, scriptable with altool.exe runtests <codeunitId> --environmentname <env> --environmenttype Sandbox --tenant <id> --company <name>, which needs no test-runner app on the environment
tags: [testing, test-runner, sandbox, saas, no-docker, bccontainerhelper, dev-endpoint, auth, silent-failure]
metadata:
  type: reference
provenance: observed
verified: 2026-09-13
---

**Symptom.** A test suite that ran fine on an online sandbox a month earlier fails with
`Cannot build the page 130455. The metadata object Page 130455 was not found.` (BcContainerHelper
`Run-TestsInBcContainer -compilerFolder` without `-containerName`, i.e. the connectFromHost branch that
drives page 130455 "Command Line Test Tool" over the client service). Page 130455 belongs to Microsoft's
"Test Runner" app. `Get-BcEnvironmentInstalledExtensions` on every environment of the tenant showed no
Test Runner / Library Assert / Any / Library Variable Storage at all.

**Why it disappears.** Test framework apps installed on a sandbox are Dev-scoped and are uninstalled on every
platform update or environment relocation (documented sandbox behaviour). Copies of production do not carry
them either.

**Why it cannot come back.** Publishing `Microsoft_Test Runner.app` (taken from the platform artifact,
`Applications\TestFramework\TestRunner\`) through the developer endpoint
(`Publish-BcContainerApp -useDevEndpoint`) is refused with HTTP 422:
`Cannot publish extension Test Runner by Microsoft ... because the publisher is "Microsoft". The service
prohibits publishing Microsoft extensions in the tenant scope.` Global PTE publishing is refused for the same
reason. There is no supported way left to put the Microsoft test framework on an online sandbox.

**The replacement (BC 28 / AL Language extension 18, 2026 wave 1).** Tests run through the developer
endpoint of the environment, without any test-runner codeunit or app installed there. VS Code exposes it as
the Test Explorer; from the command line the same engine is `altool.exe`, shipped in the AL extension
(`<extension>\bin\altool.exe`, .NET 10):

```
altool runtests <testCodeunitId> --environmentname <sandboxName> --environmenttype Sandbox --tenant <tenant-guid> --company "My Company" --raw
```

- `--raw` prints a per-method PASS/FAIL list plus `Test run completed: N passed, M failed, K skipped`;
  without it the output is structured JSON. `--testmethods A,B` filters methods; `--testgroups file.json`
  runs several codeunits over one connection.
- Authentication is Entra ID through the MSAL cache the VS Code AL extension already holds
  ("Using VS Code authentication: token issued for user ..."); with an empty cache it starts an interactive
  login (`altool auth login`). On a CI runner there is no VS Code cache - plan the auth separately.
- Tests do NOT run under an AL `TestRunner` codeunit: isolation comes from the test codeunit's
  `RequiredTestIsolation` property (default: Codeunit); test-runner setup/teardown events are not available.
- The test app itself still has to be on the environment (Global PTE publish of the test app is fine - it is
  your publisher, not Microsoft's) and must depend on the app version installed there.
- **The session runs in the user's own language.** A test that reads a report dataset and compares
  enum texts (`Format(ItemLedgerEntry."Entry Type")` gives `Sale` in English, `Vânzare` in Romanian) fails
  for every row when the user's Business Central language is not English, although the report is correct.
  Older runs through page 130455 happened to use English, so the failure only appears after switching to
  altool. Fix in the test, not in the app: `OldLanguage := GlobalLanguage(); GlobalLanguage(1033);` around
  the report run, then restore.
- Production environments refuse test runs; sandboxes allow them (Microsoft asks for at most 1-2 hours of
  test runs per day).

**Why:** a CI/CD or local test route that depends on the Microsoft test framework being installed on a
SaaS sandbox silently rots at the next platform update and cannot be repaired; the dev-endpoint route has
no such dependency.
**How to apply:** replace any page-130455 / `Run-TestsInBcContainer` test-runner script with an
`altool runtests` wrapper (one call per test codeunit, parse the summary line for the exit code); keep
`Publish-PerTenantExtensionApps` for publishing the test app. altool 18 needs .NET 10 - if the runtime is
installed per user, set `DOTNET_ROOT` (see [[bccontainerhelper-altool-path-al18-bin-layout]]). Related:
[[bcauthcontext-device-login-aadsts65002]] (the API/publish token is a different client + scope story).
