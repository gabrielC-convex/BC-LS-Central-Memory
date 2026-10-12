---
name: store-inventory-worksheet-transfer-vs-picking-to-location
description: To move stock between two locations of one store use the Store Inventory Worksheet with Worksheet Type = Transfer (posts a plain Item Journal Transfer line, no in-transit, no transfer order); the Retail Picking "To Location" / "Posting Action" fields are not a move and are rejected on picking lines
tags: [retail, warehouse, posting, transfer-order, silent-failure, pages]
metadata:
  type: reference
provenance: observed
verified: 2026-09-07
---

Verified in LS Central 27.0.24 source.

**Store Inventory Worksheet, Worksheet Type = Transfer** (`LSC Store Inventory Management`,
posting procedure): builds a temporary Item Journal Line with `Entry Type = Transfer`,
`Location Code` = worksheet header location, `New Location Code` = line, `Reason Code` = line, and
runs `Item Jnl.-Post Line.RunWithCheck`. Result: two item ledger entries with one document number
(−n at the source, +n at the destination), cost carried by application, **no in-transit location,
no Transfer Order, no journal template**. Details worth knowing:

- filling the header's `New Store Code` locks `New Location Code` on every line (the page disables
  the line field), so operators only type item + quantity;
- the header `Reason Code` defaults onto each new line and is inherited by both ledger entries —
  a subscriber on `OnBeforeInsertItemLedgEntry` sees it on the mirrored (transfer-in) entry too,
  because codeunit 22 raises the event for that entry as well;
- a line whose source has no stock is **logged and skipped, not errored** (worksheet line log /
  "line in error"): a posting can succeed partially without a dialog — check the log;
- the worksheet is store-scoped and can be opened from a POS button via a run-object of type
  Codeunit that resolves the store from `LSC POS Session.StoreNo()` and calls
  `StoreInvMgt.EditWorksheet(Worksheet, '')`.

The standard BC **Item Reclassification Journal** posts the same entries through the same engine but
is not store-scoped and has no LS Central availability warning. **Transfer Orders** need an
in-transit location (unless Direct Transfer) and two documents per move — overkill for an
intra-store move.

**Retail Picking "To Location" / "Posting Action" are not a move.** On a picking document the only
legal posting actions are blank / "Adjust Order" (`TestCombinationSetup`); where allowed at all,
"To location" books a one-sided Positive Adjustment at the target and "Return" creates a new Purchase
Return Order. What does matter on a picking is the **header** `Location Code` (the location the
return shipment leaves from, validated through StoreLocationOk); it is reset to the store's primary
when Store No. is validated and when the page opens, so it must be chosen per document. A mismatch
between the header location and a line's `To Location` posts a silent Negative + Positive adjustment
pair with no reason (`PickingReceiving - Post`), so either configure a PR Counting Posting Setup row
per location or make the header choice part of the procedure.
