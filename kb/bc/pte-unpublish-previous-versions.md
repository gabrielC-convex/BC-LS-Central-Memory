---
name: pte-unpublish-previous-versions
description: Publish-PerTenantExtensionApps leaves every superseded version published-but-uninstalled forever unless you pass -unpublishPreviousVersions, so the environment slowly fills with inert duplicate tiles of the same app
tags: [pte, saas, publish, extension, version, unpublish, bccontainerhelper, troubleshooting]
metadata:
  type: reference
provenance: observed
verified: 2026-07-31
---

Upgrading a per-tenant extension with `Publish-PerTenantExtensionApps` installs the new version
but does **not** remove the old one. The superseded version stays *Published, Is Installed = No*
indefinitely, showing as an extra tile of the same app in Extension Management. After a few
upgrades the list is mostly ghosts, and "which version is actually live?" stops being obvious.

```powershell
Publish-PerTenantExtensionApps -bcAuthContext $ctx -environment $env `
    -appFiles $appFile -SchemaSyncMode Add `
    -unpublishPreviousVersions          # <- without this, the old version never goes away
```

The switch calls the automation API's unpublish action on the superseded package after the new
version installs successfully. It requires Application 25.4 or newer.

To clean up versions that predate the fix, unpublish them explicitly — this is the action the
switch itself uses:

```
POST .../extensions({packageId})/Microsoft.NAV.unpublish
```

Confirmed on live environments: with the switch, the old version disappears entirely rather than
merely being uninstalled.

**Why:** the leftovers are inert, so nothing breaks and nobody notices — until someone reads the
extension list to answer "what is deployed", or an upgrade path has to reason about which
versions exist.

**How to apply:** put the switch in the deployment script rather than in a runbook, so it cannot
be forgotten. Judge deployment success by the "successfully published" / "Completed" line, not by
the process exit code — the cmdlet shells out to docker at load and returns a non-zero exit on
machines without it, which is noise, not failure.
