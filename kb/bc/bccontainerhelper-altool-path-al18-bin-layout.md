---
name: bccontainerhelper-altool-path-al18-bin-layout
description: AL Language extension 18.0 moved alc.exe and altool.exe from bin\win32\ to bin\ and targets .NET 10; BcContainerHelper 6.1.12 still hardcodes extension/bin/win32/altool.exe for Publish-PerTenantExtensionApps, so every Global PTE publish dies with "Command ...\bin\win32\altool.exe not found" once the helper downloads the 18.x VSIX - mirror bin\ into bin\win32\ in the helper cache and set DOTNET_ROOT to a .NET 10 runtime; build scripts that probe only bin\win32\alc.exe report a false exit 0
tags: [bccontainerhelper, publish, pte, saas, silent-failure, troubleshooting, alpackages]
metadata:
  type: reference
provenance: observed
verified: 2026-09-13
---

**Symptom 1 - publish.** `Publish-PerTenantExtensionApps` (BcContainerHelper 6.1.12) prints the environment's
"Extensions before:" list, then throws from `HelperFunctions.ps1:139`:
`Command C:\ProgramData\BcContainerHelper\alLanguageExtension\18.0.2732683\extension\bin\win32\altool.exe not
found, you might need to install that command.` Nothing was uploaded. The helper always downloads the LATEST
AL Language VSIX from the marketplace into `<hostHelperFolder>\alLanguageExtension\<version>` and uses
`altool` from it to read the app manifests (`RunAlTool` -> `extension/bin/win32/altool.exe`, hardcoded, no
config knob; `DownloadLatestAlLanguageExtension` has no version pin).

**Symptom 2 - compile.** A build script that resolves
`$env:USERPROFILE\.vscode\extensions\ms-dynamics-smb.al-*\bin\win32\alc.exe` gets an empty path after the
VS Code extension upgrades to 18.0; `& $alc` then fails as a PowerShell error, not a process exit code, and a
script ending in `exit 0` reports a successful build that never ran.

**Symptom 3 - runtime.** alc/altool 18 target `net10.0`. With only the machine-wide .NET 8 installed they die
with "You must install or update .NET to run this application" (exit 150) even when a .NET 10 runtime exists
per user under `%LOCALAPPDATA%\Microsoft\dotnet` - the apphost does not look there unless `DOTNET_ROOT` says so.

**Fixes that worked.**
- Helper cache: copy the content of `...\18.0.x\extension\bin\` into `...\bin\win32\` (robocopy with `/E`,
  excluding the target itself; ~53 MB, self-contained because altool's DLLs and runtimes ride along).
  Reversible, no admin rights. Re-check after each new VSIX version the helper downloads.
- Build scripts: probe both `bin\win32\alc.exe` and `bin\alc.exe`, newest extension first, and `throw` when
  neither exists - never let a missing compiler fall through to `exit 0`.
- Set `$env:DOTNET_ROOT = "$env:LOCALAPPDATA\Microsoft\dotnet"` for the process when that folder holds
  `shared\Microsoft.NETCore.App`, before invoking alc/altool or any BcContainerHelper cmdlet that shells to altool.

**Why:** the failure sits in tooling the deploy script trusts implicitly; a false-green build or a publish that
dies before upload looks like an environment problem and costs an afternoon.
**How to apply:** after every AL extension major upgrade, run the build once in the foreground and read the
compiler banner (`alc: <path>`, `Microsoft (R) AL Compiler version ...`) before believing any exit code; check
the BcContainerHelper cache layout before a Global PTE publish. Related: [[al-tests-on-online-sandbox-altool-runtests]]
(altool runtests has the same .NET 10 requirement).
