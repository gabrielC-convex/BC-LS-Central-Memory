---
name: public-symbol-nuget-feeds
description: Microsoft and AppSource (incl. LS Central) symbols are downloadable from two public NuGet feeds with no tenant login — but Find-BcNuGetPackage silently misses them without an explicit feed URL
tags: [symbols, nuget, feed, alpackages, BcContainerHelper, MSSymbols, AppSourceSymbols, download, no-docker]
metadata:
  type: reference
provenance: observed
verified: 2026-07-30
---

`AL: Download Symbols` in VS Code is not the only way. Microsoft publishes two public NuGet
feeds that serve the same packages with **no authentication**, usable via
`Download-BcNuGetPackageToFolder` (BcContainerHelper):

| Feed | Content |
|---|---|
| `https://dynamicssmb2.pkgs.visualstudio.com/DynamicsBCPublicFeeds/_packaging/MSSymbols/nuget/v3/index.json` | Microsoft platform + application |
| `https://dynamicssmb2.pkgs.visualstudio.com/DynamicsBCPublicFeeds/_packaging/AppSourceSymbols/nuget/v3/index.json` | third-party AppSource apps (incl. LS Retail) |

Package naming convention: `<Publisher><Name>.symbols.<appId>`, no spaces — e.g.
`LSRetail.LSCentral.symbols.5ecfc871-5d82-43f1-9c54-59685e82318d`. For Microsoft:
`Microsoft.Application.symbols` (pulls Base App, System App, Business Foundation via
`-downloadDependencies all`) and `Microsoft.Platform.symbols`.

**Traps, each verified:**

- `Find-BcNuGetPackage` **without** `-nuGetServerUrl` does NOT find AppSource packages — the
  default feed is a different one. Always pass the feed URL explicitly, or query the
  `SearchQueryService` endpoint from the feed's `index.json` directly.
- `-downloadDependencies all` on an AppSource feed does **not** resolve Microsoft dependencies —
  download those separately from MSSymbols.
- Some country-specific variants (`.AT.`, `.W1.` suffixes) resolve arbitrarily; prefer the
  suffix-free package and pass `-installedCountry`.
- Pick the version by what is **installed on the target tenant**, never the newest in the feed —
  see [[al1024-dependency-version-trap]].

**Why:** removes the tenant-login dependency from CI and from any scripted build; symbols
become reproducible artifacts instead of an interactive VS Code step.

**How to apply:** inventory installed versions first, then `Download-BcNuGetPackageToFolder
-nuGetServerUrl <feed> -packageName <name> -version <exact> -select Exact -folder .alpackages`.
