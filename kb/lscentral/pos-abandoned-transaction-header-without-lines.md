---
name: pos-abandoned-transaction-header-without-lines
description: An LS Central POS transaction that is started and abandoned (e.g. an inventory adjustment where the cashier backs out before adding an item) still leaves a Transaction Header with a receipt number and transaction type — but no lines, no infocode entries and no stock effect; count adjustments by their lines, never by headers
tags: [pos, retail, report, posting, misleading, troubleshooting]
metadata:
  type: reference
provenance: observed
verified: 2026-10-07
---

When a cashier starts a POS transaction of a non-sale type — observed with **negative inventory
adjustments** (`Transaction Type = NegAdj`, the usual "trial / replacement" flow) — and backs out
before any item is rung, LS Central still writes a `LSC Transaction Header` row:

- it gets the next **transaction number** and the next **receipt number** on that terminal;
- `Transaction Type` is the type the button started (`NegAdj`), not `Voided`;
- there are **no** `LSC Trans. Inventory Entry` rows, **no** `LSC Trans. Sales Entry` rows and
  **no** `LSC Trans. Infocode Entry` rows (the reason-code popup is part of the item flow, so it
  never ran);
- nothing is posted: no Item Ledger Entry, nothing in statement-based stock reports.

Why it misleads: a query that counts "adjustments without a reason code" by joining headers to
infocode entries reports every abandoned header as a missing reason. On a live tenant (verified
October 2026, 5 weeks of data) that join returned 203 "adjustments without reason"; after joining
the inventory lines, **202 were empty headers** and exactly one was a real adjustment whose reason
popup had been skipped. A quarter of the abandoned headers were followed within 15 minutes, on the
same terminal, by a properly coded adjustment — the cashier simply started over.

How to apply:
- when auditing POS adjustments, returns or any non-sale type, join to the **line tables** first
  and drop headers with zero lines; report the empty headers separately as "started, not completed"
  if at all;
- the same holds for receipt-number gaps: an abandoned transaction consumes a receipt number
  without printing anything, so a gap in receipt numbers is not by itself a missing fiscal receipt;
- BC OData on the `api/<publisher>/<group>/v1.0` custom API pages rejects filters that `or` together
  groups of `and` on different fields (`BadRequest_MethodNotImplemented`); fetch per terminal by a
  `transactionNo ge X and transactionNo le Y` range and filter client-side instead.

Related: [[pos-item-posting-immediate-vs-statement-document-no]] (how the lines reach the ledger),
[[pos-run-objects-and-commands]].
