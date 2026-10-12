---
name: pos-item-posting-immediate-vs-statement-document-no
description: Item ledger entries for POS sales look different depending on when LS Central posts them - immediate posting (POS Functionality Profile "Automatic Stock Update") writes one ILE per transaction with Document No. = <store>-<terminal>-<transaction no>, while statement posting aggregates all receipts of the day per item (buffer key) into one ILE whose Document No. is the statement posting no.; LSC Trans. Inventory Entry."Statement No." is the bridge back to the receipt lines
tags: [pos, posting, retail, report, fields]
metadata:
  type: reference
provenance: observed
verified: 2026-09-08
---

Verified in LS Central 27.0.24 source; behaviour confirmed live on a 28.x tenant running with immediate posting.

**Immediate path** - `LSC POS Post Utility.ProcessTransaction` calls `LSC POS Order Connection.PostItemInventory`
only when `POS Functionality Profile."Automatic Stock Update"` is on. `PostItemInventory` builds the item posting
buffer for that single transaction with `Document No. := CreateDocNo(Store No., POS Terminal No., Transaction No.)`,
i.e. `<store>-<terminal>-<transaction no>`, so every receipt produces its own item ledger entries (one per item /
salesperson / offer / promotion combination inside the receipt). The receipt posting transaction then also carries
the whole item and value entry posting, plus G/L cost posting when Inventory Setup "Automatic Cost Posting" is on.

**Statement path** - `LSC Statement-Post` skips lines already at status "Items Posted" and, for ordinary sales
transactions, calls `PostItemSales(..., Statement."Posting No.", ...)`: the buffer's Document No. is the **statement
posting number**, not the receipt. Only "To Account" transactions (posted to a customer) keep the per-transaction
`CreateDocNo`. Because the buffer's primary key is (Type, Item No., Location, Department, Document No., Source No.,
Serial, Lot, Date, Salesperson, Neg. Qty, Currency, Offer No., Promotion No.), all receipts of the day for one item
collapse into a single item ledger entry per distinct salesperson / offer / promotion. Posting Date stays the
transaction date when Retail Setup "Item Posting Date" = Transaction Date (the buffer key includes Date).

**Consequences for reporting**

- A report that derives the receipt from the ILE Document No. (splitting `<store>-<terminal>-<transaction no>`)
  works only with immediate posting. Switching "Automatic Stock Update" off silently changes the ILE shape: fewer
  rows, statement numbers as document numbers, no per-receipt granularity.
- The bridge that survives both modes is `LSC Trans. Inventory Entry`: one row per posted transaction line with
  Store / Terminal / Transaction No. / Line No. and `Statement No.` equal to the ILE Document No. of the statement
  path. Expanding an aggregated ILE through that table restores per-line detail (salesperson, offer, receipt).
- Adjustment-type POS lines (Negative/Positive Adjmt.) are always posted at statement time and are therefore
  aggregated even when immediate posting is on.
