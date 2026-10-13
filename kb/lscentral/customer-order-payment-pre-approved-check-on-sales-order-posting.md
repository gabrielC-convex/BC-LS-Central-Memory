---
name: customer-order-payment-pre-approved-check-on-sales-order-posting
description: Posting the Sales Order made from an LS Central Customer Order stops unless the order carries a complete pre-approved payment - valid payment rows, a tender type and a G/L account for that store, and Pre Approved Amount covering the order; Finalized Amount does not count. The check is a subscriber to Sales-Post OnBeforePostSalesDoc in LSC CO eCommerce Mgt, and its error texts name each missing piece
tags: [posting, retail, error-message, events, integration-event, version, troubleshooting]
metadata:
  type: reference
provenance: observed
verified: 2026-10-13
---

A Customer Order that came in through the web service (`CustomerOrderCreateDoc`) is turned into a
Sales Order. When that Sales Order is posted - shipped or invoiced - LS Central checks the order's
payment first and stops the posting at the first thing that is missing. The behaviour was verified
on a live LS Central 28 system; the rule below was then read in the source of 28.1.0.1807
(identical in 28.2.12).

Where: codeunit 10016657 `LSC CO eCommerce Mgt`, `BeforeSalesOrderPost`, a subscriber to
`Sales-Post.OnBeforePostSalesDoc`, which calls `SalesOrderBeforePosting` for every Sales Order whose
`LSC Customer Order ID` is filled in. In order:

| # | What must be there | Error when it is not |
|---|---|---|
| 1 | Rows in `LSC Customer Order Payment` for the order that are still valid: `Pre Approved Valid Date` empty or not in the past, `Authorization Expired` = false | only expired rows: `Pre approval expired %1,` - no row at all and the order total is not 0: `Customer Order payment missing for Customer Order %1.` |
| 2 | For each row, the `LSC Tender Type` of **that store** (`Store No.` + `Tender Type` of the row) | `Tender Type %1 not found in Store %2` |
| 3 | For each row, a G/L account: the tender type's own if its Account Type is G/L Account, otherwise the one behind the store's `Customer Order Inc/Expense Acc` (an `LSC Income/Expense Account` of that store); the account must allow Direct Posting | `"Customer Order Inc/Expense Acc" setup missing for Store %1` - `G/L Account setup missing for Store %1, Tender Type %2` |
| 4 | Sum of **`Pre Approved Amount`** over the valid rows + the header's `Rounding Amount` >= the Sales Order's `Amount Including VAT` | `Pre approved payment for web order %1 is lower than Sales order %2 \Payment Amount %3 vs. Sales Amount %4.` |
| 5 | When invoicing an amount: the payment is posted and a POS transaction is created from the order | the posting error, or `Error Posting Customer Order Payment.` |

What follows from it:

- **`Finalized Amount` is not in the sum.** An order whose payment rows carry only a finalized
  amount fails at step 4 exactly like an order without payment.
- An order with total 0 (a 100 % discount) passes step 1 without any payment row.
- Tender types and income/expense accounts are **per store** (`Store No.` is part of both keys), and
  the store is the one on the *payment row*. A tender code that works in one store stops the posting
  in another where it was never created.
- From 28.1 an extension can take over step 4 through
  `OnBeforeCheckPreApprovedAmount(var CustomerOrderHeader, var SalesHeader, var PreApprovedAmount, var IsHandled)`.

Version differences (found by comparing the source of the three versions):

- **27.0.24** sums `Pre Approved Amount LCY`, not `Pre Approved Amount`, and has no
  `OnBeforeCheckPreApprovedAmount` event; the rest of the sequence is the same.
- 27.0.24 also contains a procedure `PostCustomerOrderPayment` with near-identical code that
  **nothing calls**; it is gone in 28.1. Reading it as "the rule" gives the wrong comparison (against
  the amount to collect instead of the Sales Order total) - check that a procedure has a caller
  before quoting it.

How to apply:
- when the posting of a web order stops, read the error text against the table: each message names
  one missing piece, and fixing it reveals the next;
- when creating orders through the web service, send the payment as *pre-approved* for the full
  amount including VAT, with a tender type that exists in the store the payment row names;
- payment taken at the till goes through other code (`LSC CO Utility`) - do not carry this rule over
  to POS-created orders without checking.

Related: [[customer-order-header-exclude-collect-ship-internal-fields]] (same area, same lesson about
reading the version that actually runs).
