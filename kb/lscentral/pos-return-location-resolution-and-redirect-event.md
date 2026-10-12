---
name: pos-return-location-resolution-and-redirect-event
description: A POS refund line carries no location — LS Central resolves Store."Location Code" (Sales Type override only) at item-posting time on both the immediate and the statement path; there is no "return location" setting, and the only hook to post a return elsewhere is OnBeforeInsertItemPostingBufferSalesV2, which runs inside the receipt's posting transaction
tags: [pos, posting, integration-event, events, retail, silent-failure]
metadata:
  type: reference
provenance: observed
verified: 2026-09-07
---

Verified in LS Central 27.0.24 source (method bodies); event names also present in 28.x symbols,
line numbers indicative.

**Where a POS line's location comes from.** `LSC Trans. Sales Entry` has no Location Code field
(the special-order fields on POS Trans. Line are not used by item posting). The location is decided
only when the item journal buffer is built:

- immediate path — POS Functionality Profile `Automatic Stock Update` → `LSC POS Post Utility`
  (`PostItemInventory` call) → `LSC POS Order Connection.ProcessItemSales`:
  `xLocCode := Store."Location Code"`, overridden by `LSC Sales Type."Location Code"` when the line's
  (or header's) Sales Type has one;
- statement path — `LSC Statement-Post.PostItemSales`: identical rule, and it skips lines already at
  status "Items Posted" by the immediate path.

A refund is a normal Sales-type transaction whose line quantity is negated into the buffer, so the
return ILE is `Entry Type = Sale`, positive quantity, at the store's primary location. **There is no
"Return Location" / "Refund Location" field anywhere in LS Central** (grep of every field
definition). The Posting Exception "Sourcing Location" applies to sales too, so it cannot express a
return-only rule; a Sales Type override drags VAT/price/dimension semantics along.

**The one redirect point.** Both codeunits raise
`OnBeforeInsertItemPostingBufferSalesV2(var ItemPostingBuffer, var TransSalesEntry, var TransactionHeader)`
immediately after the location is set and before `UpdItemPostingBuffer` stores the row. The buffer's
primary key includes Location Code, so a subscriber that changes `ItemPostingBuffer."Location Code"`
produces its own journal line; no LS Central code re-derives the location afterwards (the journal line
copies the buffer verbatim). Things a redirect subscriber must respect:

- it runs **inside the receipt's posting transaction**, after payment lines are written and before the
  Commit; any error aborts the receipt at the till, and `POS Transaction Functions.PostAndDeleteTransaction`
  retries `Maximum Posting Tries` times with growing Sleep before failing — a deterministic error becomes
  a long freeze plus a receipt left open. Early exits only, no `Error()`.
- guard on `Buffer.Type = Sales`: lines with "Linked No. not Orig." are turned into `Type::NegAdjust`
  through the **same** event.
- be symmetric on undo (`glUndoItemPosting` posts the reversal through the same event with the sign
  flipped on the buffer).
- the buffer has no reason field; stamp `Item Journal Line."Reason Code"` (field 42) and/or the standard
  `"Return Reason Code"` (6600, copied by codeunit 22 to ILE field 6602) one hook later:
  `OnBeforePostItemPostingBufferRecV2` (POS Order Connection) / `OnBeforeItemJnlLinePostLineV2`
  (Statement-Post). LS Central itself never fills either field on POS lines.
- `LSC POS Transaction Events.OnAfterPostPOSTransaction` fires **after** Commit — too late to redirect,
  usable only for a follow-up reclassification.
- Negative Adjustment transactions (e.g. replacements done through a NegAdj button) never write Trans.
  Sales Entry and are posted only at statement time through `PostNegAdjustment` /
  `OnBeforePostNegAdjV2` — a different path.
