---
name: al-setloadfields-runtime-trap
description: SetLoadFields with an explicit field list turns every later field read into a runtime error, and the compiler stays green — so adding one field to a report or codeunit means finding every SetLoadFields on the path
tags: [al, fields, silent-failure, error-message, troubleshooting, report]
metadata:
  type: reference
provenance: observed
verified: 2026-08-04
---

`SetLoadFields` is a partial-record optimisation: it tells the platform to fetch only the named
columns. Anything not named is **not loaded**, and touching it afterwards raises

> The field ... of table ... is not loaded.

**The trap is the timing.** That error appears at *runtime*, never at compile time. A green build
is not evidence that the code works. So the sequence that bites is ordinary maintenance:

1. someone adds a field read to an existing procedure — say a new column on a report;
2. the build passes, because the field genuinely exists on the table;
3. the report throws for every row, in front of whoever ran it.

## What to do when adding a field read

Find **every** `SetLoadFields` on the call path, not just the obvious one. In a report the same
record variable is often loaded in two or three places — the dataitem trigger, a helper that
re-reads the record, a second pass over a different filter — and only the paths you miss will
fail. Grep the whole app for `SetLoadFields`, then decide per site whether the new field belongs.

A helper procedure that receives a record parameter is the dangerous case: it cannot see which
fields its caller loaded, and it compiles regardless. The field list lives with the caller, the
field read lives with the callee, and nothing connects them.

**Why it costs more than it looks:** the failure is invisible to the two checks people trust —
compilation and code review — and shows up only when the object is actually executed against
data. If the object is a report someone runs monthly, the gap between shipping and discovering
can be weeks.

**How to apply:** treat `SetLoadFields` as a hand-maintained dependency list. When a review
touches a field read, the review also asks "which `SetLoadFields` does this reach?" — and when
it is not obvious, drop the optimisation rather than guess. The read cost of a full record is
almost always smaller than the cost of a report that fails at the user.
