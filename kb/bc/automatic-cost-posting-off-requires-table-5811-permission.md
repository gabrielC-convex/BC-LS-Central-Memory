---
name: automatic-cost-posting-off-requires-table-5811-permission
description: Turning Inventory Setup "Automatic Cost Posting" off makes codeunit 22 insert a "Post Value Entry to G/L" (table 5811) row for every value entry, so any user who posts inventory (POS receipts included) suddenly needs Insert on 5811 - users without D365 BUS FULL ACCESS fail with "permissions prevented the action (TableData 5811 ... IndirectInsert: Base Application)" at the till
tags: [posting, permissionset, pos, error-message, troubleshooting, silent-failure]
metadata:
  type: reference
provenance: observed
verified: 2026-09-09
---

**Symptom.** The morning after Inventory Setup "Automatic Cost Posting" was switched off on a live tenant, one
store's POS could not close any receipt. Error at the till:

```
Din păcate, permisiunile curente au împiedicat acțiunea. (TableData 5811 Post Value Entry to G/L ... IndirectInsert: Base Application)
```

AL call stack: `Item Jnl.-Post Line (CU 22).InsertPostValueEntryToGL` <- `InsertValueEntry` <- `ItemValuePosting`
<- `PostItem` <- `RunWithCheck` <- `LSC POS Order Connection.PostItemInventory` <- `LSC POS Post Utility.ProcessTransaction`.
Every other store kept selling normally, which made the setup change an unlikely suspect at first.

**Mechanism.** With Automatic Cost Posting on, codeunit 22 posts inventory cost to G/L inline and never touches
table 5811. With it off, `InsertPostValueEntryToGL` queues each new value entry in "Post Value Entry to G/L" for the
"Post Inventory Cost to G/L" batch. That insert runs under the posting user's permissions (indirect insert). Users
holding `D365 BUS FULL ACCESS` have it; a user with only `D365 READ` + product permission sets (LS Central, ISV sets,
a custom supervisor set) does not, even though inventory posting itself worked for them until then.

**Why one store only.** Per-store BC users are rarely provisioned identically. On this tenant the failing store's user
lacked `D365 BUS FULL ACCESS`, all others had it. Compare users quickly through the automation API:
`GET /api/microsoft/automation/v2.0/companies({id})/users({userSecurityId})/userPermissions`.

**Fix / rule.** Before flipping Automatic Cost Posting (or Expected Cost Posting, or Automatic Stock Update): list the
permission sets of every user that posts inventory and test with the weakest one, not with SUPER. Durable fix: add
TableData 5811 (Insert, Modify, Delete) to the custom permission set shared by all POS users, so nobody depends on
`D365 BUS FULL ACCESS`. Immediate fix: assign the missing set (permissions apply on the user's next session, so the POS
must log off and on) or set Automatic Cost Posting back on.

Secondary symptoms seen on the stuck receipt: cashiers re-pressing tenders produce "Overtendering is not allowed for
this tender type" and stray cash lines; the card payment had already been approved by the bank, so the recovery is to
remove the extra tender lines and finish the receipt, never to re-tender the card.
