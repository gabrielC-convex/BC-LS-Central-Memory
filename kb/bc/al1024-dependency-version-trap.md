---
name: al1024-dependency-version-trap
description: AL1024 at publish shows the REQUESTED version, not the found one — the real cause is a dependency in app.json pinned newer than what the tenant runs; AL0247 that follows is just fallout
tags: [AL1024, AL0247, dependency, version, publish, dev-endpoint, error-message, misleading, app.json]
metadata:
  type: reference
provenance: observed
verified: 2026-07-30
---

The cloud dev endpoint rejects a publish with:

```
error AL1024: A package with publisher 'X', name 'Y', and a version compatible with 'N.N.N.N'
could not be loaded. The requested app 'Y' ... is found with version N.N.N.N ... that doesn't
meet minimum version requirements.
error AL0247: The target Page 'Z' for the extension object is not found
```

**The message lies:** "is found with version N.N.N.N" prints the version you *requested*, not
the one installed on the tenant. The real cause is that `dependencies` in `app.json` declares a
version **newer** than what the tenant actually runs. `AL0247` is pure fallout — with the
package not loaded, the extended object does not exist for the server-side compiler.

**Why:** symbols pulled from public NuGet feeds are the *latest published* version, which is
routinely ahead of what any given tenant has installed. It is natural to pin `app.json` to the
package you downloaded — and that is exactly the mistake.

**How to apply:** always read the installed versions from the target tenant first
(`Get-BcInstalledExtensions -bcAuthContext ... -environment ...`), download symbols pinned to
**exactly those versions** (`-select Exact`), and let the dependency entries be generated from
the downloaded packages' `NavxManifest.xml`. Never infer versions from a feed. See
[[public-symbol-nuget-feeds]].
