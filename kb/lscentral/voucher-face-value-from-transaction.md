---
name: voucher-face-value-from-transaction
description: A voucher line's real value lives on the transaction line (Deal Line Added Amt., field 1034) — reading it from the deal's master data instead makes historical reports change when someone edits the offer
tags: [pos, retail, report, al, fields, posting, troubleshooting]
metadata:
  type: reference
provenance: observed
verified: 2026-08-04
---

A voucher rung at an LS Central POS is an item like any other, but its **item price is a
placeholder** — typically 0.01, sometimes 0. The amount the customer actually got off is held
elsewhere, and there are two different "elsewhere"s. They look interchangeable and are not:

| Source | Table | Nature |
|---|---|---|
| `Added Amount` | `LSC Deal Modifier Item` | **master data** — the offer's current configuration |
| **`Deal Line Added Amt.`** (field **1034**) | `LSC Trans. Sales Entry` | **stamped on the line at sale time** |

Both hold the same number while the offer is untouched, so a report reading either one looks
correct on the day it is written.

## Why master data is the wrong source

Offers get edited. Remove the voucher item from the deal — a perfectly ordinary piece of
housekeeping — and the master-data lookup finds nothing. A report that falls back to the item's
own price then reports the **placeholder**: a 30.00 discount becomes 0.01, silently, on
transactions that were posted months earlier and have not changed at all.

That is the real defect: reading master data makes *history mutable*. Nobody edits a past
receipt, yet the report about it changes.

`Deal Line Added Amt.` is written onto the transaction line when the sale happens and is never
revisited, so it keeps reporting what was actually given.

## How to apply

Read field 1034 first; keep the master-data lookup only as a fallback for transactions posted
before the field was populated. That ordering is safe in both directions — where 1034 is zero
the behaviour is byte-identical to the old chain, and where it is set it is authoritative.

Two things worth checking on real data before trusting it, because the symbol metadata does not
say:

- **whether 1034 is per unit or per line.** If the caller multiplies by quantity, the two
  readings agree only at quantity 1 — which is most voucher lines, so the bug hides.
- **field 1035 `Deal Modifier Added Amt.`** sits right next to it and its name matches the
  master-data source more literally. If 1034 is empty on a given dataset, try 1035 before
  concluding the approach fails.

**The general shape:** when a report about the past reads current configuration, it is not a
report, it is a simulation. Prefer whatever the posting process stamped onto the record. See
also [[pos-discount-layers]] for the neighbouring trap — the voucher's value belongs to the
line discount layer and must not be added to the deal layer.
