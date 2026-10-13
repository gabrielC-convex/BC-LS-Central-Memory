---
name: how-to-tell-what-was-removed-between-versions
description: How to find out whether something in LS Central was removed, when, and what replaces it - the vendor's package carries the full AL source of its version, the code marks what is obsolete (state, version, reason), and two versions can be compared; the help's topics carry no "applies to" version, so neither their presence nor their age proves anything
tags: [version, fields, events, symbols, download, documentation, verification, retail]
metadata:
  type: reference
provenance: observed
verified: 2026-10-13
---

Three sources, from the most exact to the most general.

**1. The code of the version in question.** The LS Central package that an environment's dev
endpoint hands out (the same `.app` the compiler uses for symbols) contains the complete AL source
of that version under `src/` - its manifest says `AllowDownloadingSource="true"
IncludeSourceInSymbolFile="true"`. A production environment does not serve it; a sandbox on the
same version does. If the object, field or procedure is in that source, it exists in that version,
whatever the help says or does not say.

**2. What the code itself marks as obsolete.** Before deleting anything the vendor marks it:

- objects, fields, page controls, actions, enum values: `ObsoleteState = Pending` (still works, the
  compiler warns) or `Removed` (can no longer be used), with `ObsoleteTag` (the version it was
  marked in) and `ObsoleteReason` (usually naming the replacement);
- procedures and events: `[Obsolete('reason', 'tag')]`.

Counted in the source of 28.1: about 2,200 marked elements - 770 removed, 1,430 pending - with tags
from 18.4 up to 29.0. Removed table fields stay in the table as markers (767 of the 770 carry tag
25.0, one clean-up of the Customer Order tables), so a single version shows schema removals from
many versions back. A tag higher than the running version is an announcement.

**3. Comparing two versions.** What was physically deleted is no longer in the code, marker
included, so it only shows in a comparison. Measured on real packages:

| From -> to | Objects removed | Objects added |
|---|---|---|
| 25.0 -> 26.0 | 13 | 805 |
| 26.0 -> 27.0 | 15 | 427 |
| 27.0 -> 28.0 | 73 | 485 |
| 28.0 -> 28.1, 28.1 -> 28.2 | 0 | 32, 8 |

Deletions happen in major versions; the minor ones only added. Of the 73 objects deleted in 28.0,
68 were already marked obsolete in the 27.0 code - so reading the markers of the version you are on
predicts most of what the next major takes away. Procedures are different: of some 600 deleted
between the same two versions only about a fifth carried `[Obsolete]`; local and internal
procedures disappear without notice, which matters only if you copied their logic.

**The help is the weakest of the three for this question.** A topic has no "applies to" version: a
feature built in version 10 and never touched again is not mentioned in the notes of 28, and is
still there. The vendor's stated practice is on the page *Breaking Changes* and under *Important
Notices* in each major release's notes: obsolete code is deleted in a major release once it has been
marked for at least a year. It is a practice, not a guarantee - elements marked in 20.5 are still
pending in 28.1.

How to apply:
- "is X still there in version V?" - look in the source of V, not in the help and not in another version;
- "was X removed, and what do I use instead?" - the obsolete marker on X, in the newest version that
  still has it; the reason text usually names the replacement;
- "what will the upgrade break?" - compare the two versions, and list what the current version marks
  as pending with a tag two majors back or older;
- before building on a field or event, check that it is not marked `Pending`.

Related: [[customer-order-header-exclude-collect-ship-internal-fields]] (the mirror case: something
that exists only in the newer version).
