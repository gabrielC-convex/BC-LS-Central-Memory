---
name: pos-discount-layers
description: A POS sale line carries discounts in two independent layers — the line layer (manual discount, voucher) and the deal layer (baked into the booked amounts) — and a report that adds them together double-counts
tags: [pos, retail, report, al, posting, troubleshooting, misleading]
metadata:
  type: reference
provenance: observed
verified: 2026-08-03
---

Discounts on an LS Central POS sale line do not live in one place, and the two places mean
different things:

**Layer 1 — the line layer.** Explicit, per line, and readable as its own number:
- a **manual POS line discount** (the DISCAM command) → field **`Line Discount`** on
  `LSC Trans. Sales Entry`. Note this is a *different* field from `Discount Amount` and from
  `Discount %`, all three of which can be populated at once with the same value.
- a **voucher item** — an item flagged `LSC Qty. Becomes Negative`, rung as a line whose own
  price is a placeholder (0.01). Its real face value sits on the deal, in
  `LSC Deal Modifier Item`.`Added Amount`, and is attributed to the first kept product line of
  that deal instance.

**Layer 2 — the deal layer.** A Deal (bundle/mix-and-match) offer does **not** write a discount
amount on the line. The engine bakes the reduction into the booked amounts and spreads it
across the deal's lines, leaving the line's own `Discount %` at 0. It is recovered by
comparing standard price against actually-paid, per deal instance.

## How do I report both without double-counting?

Report them in separate columns, never summed into one:

| Column | Contains |
|---|---|
| line-discount column | layer 1 only — manual line discount + voucher face value |
| discount % / gross-discount / invoiced columns | layer 2, derived from standard-vs-paid |

**Worked example, verified on a live receipt:** one sale line, list price 69.00 incl. VAT.
The line-discount column shows **−30.00** (a manual line discount), while the gross-discount
column shows **−51.00** — the same 30.00 plus 21.00 contributed by a 73.91% deal. Adding the two
columns would claim 81.00 of discount on a 69.00 item.

**Why:** the two layers look interchangeable from the data — both are "a discount on this line" —
and a report that sums them passes every arithmetic sanity check on a receipt that has only one
layer. It only goes wrong on receipts carrying both, which are the minority, so the error ships.

**How to apply:** when a second report has to agree with an existing one, copy the *composition*
of each column, not just the field list. If the existing report keeps two discount columns
apart, the new one keeps them apart too — a "simplification" that merges them is a defect.
See also [[report-excel-layout-data-table]] for why the column identifiers must then stay in
sync between the AL dataset and the Excel layout.
