---
name: retail-receiving-over-receipt-tolerance
description: LS Central retail receiving against a purchase order refuses a quantity above the ordered one ("You cannot receive more than N units" / over-receipt tolerance 0%) because the receiving line runs Business Central's Over-Receipt Code logic; the limit is the "Over-Receipt Tolerance %" of the code resolved Item, then Vendor, then the code flagged Default, and the code is stamped on the line when first evaluated, so edit the tolerance of the code already in use rather than creating a new default
tags: [retail, error-message, troubleshooting, fields]
metadata:
  type: reference
provenance: vendor-docs
verified: 2026-09-15
---

**Symptom.** In a Retail Receiving document (LSC P/R Counting, Counting Type = Receiving, Receiving = Purchase
Order), entering a quantity above the ordered one fails on the line with an over-receipt error that reports the
ordered quantity (base), the quantity already received (base) and "over-receipt tolerance is 0% or 0".

**Mechanism** (LS Central source, table `LSC Picking / Receiving lines`):
- `Quantity.OnValidate` ends with `if not OverReceiptProcessing() then Error(OverReceiptErr)`.
- `OverReceiptProcessing` applies only to receiving against a purchase order and, when Business Central's
  over-receipt feature is allowed, validates the line field `Over-Receipt Quantity`.
- `Over-Receipt Quantity.OnValidate` fills `Over-Receipt Code` on the line if empty, using
  `Over-Receipt Mgt.GetDefaultOverReceiptCode`: the item's `Over-Receipt Code` (field 8510), else the vendor's
  `Over-Receipt Code` (field 8510), else the `Over-Receipt Code` record with `Default = true`. It then builds a
  temporary purchase line and validates its over-receipt quantity, which checks the code's
  `Over-Receipt Tolerance %` (table `Over-Receipt Code` 8510).

**How to lift the limit.**
- For everybody: page "Over-Receipt Codes", open the code with `Default` on, set `Over-Receipt Tolerance %`
  (100 allows up to twice the ordered quantity), keep `Approval Required` off.
- For one vendor or one item: put a code with a higher tolerance on the vendor card or the item card; it wins over
  the default.
- Check the item and vendor cards first: if either carries a code, that is the one in effect.

**Why:** the code is stamped on the receiving line the first time it is evaluated. Editing the tolerance of the
stamped code takes effect immediately on the next validation; a brand-new default code does not reach lines that
already exist, which would have to be deleted and re-created.
**How to apply:** at posting, the purchase order quantity grows by the extra received quantity, so the vendor
invoice must match. Related: [[store-inventory-worksheet-transfer-vs-picking-to-location]].
