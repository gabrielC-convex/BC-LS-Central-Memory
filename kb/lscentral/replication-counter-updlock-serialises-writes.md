---
name: replication-counter-updlock-serialises-writes
description: Every insert/modify on an LS Central table with a Replication Counter runs FindLast with ReadIsolation UpdLock on that table's last row and holds the lock until commit, serialising all POS sessions on one row; Distribution Location "Skip Repl. Counter Update" turns the whole mechanism off (cached per session under #REPLCOUNT)
tags: [pos, posting, retail, runtime, troubleshooting]
metadata:
  type: reference
provenance: observed
verified: 2026-09-08
---

Observed on a SaaS tenant in Application Insights ("Top SQL queries that hold database locks"): the top lock
holders were `LSC POS Card Entry Logic.Trigger_OnValidate_Replication_Counter` on table `LSC POS Card Entry`,
reached (a) when a card payment starts (EFT integration inserts its log entry) and (b) when the receipt is
posted (`LSC POS Post Utility.WriteTransactionToDatabase` modifies the card entries). Average hold about 1 s.

**Mechanism** (LS Central 27.0.24 source, same code path in 28.x): the table's OnInsert and OnModify call
`Validate("Replication Counter")`. The validation asks `LSC Client Session Utility.UpdateReplicationCountersForTable`
whether counters are maintained and, if so, does

```al
PosCardEntry.ReadIsolation := IsolationLevel::UpdLock;
PosCardEntry.FindLast();
Rec."Replication Counter" := PosCardEntry."Replication Counter" + 1;
```

That is a `SELECT TOP 1 ... WITH (UPDLOCK)` on the last row of the table by primary key, held until the transaction
commits. Every writer to that table, from every store and terminal, queues on the same row. When the modify happens
inside receipt posting with `Automatic Stock Update` on, the lock is held for the whole item/value-entry posting, so a
terminal starting a card payment elsewhere waits for another store's receipt to finish posting. The pattern is
generic: about 50 "Logic" codeunits use the same helper and the same UpdLock FindLast.

**Switch:** `UpdateReplicationCounters()` reads `LSC Retail Setup."Distribution Location"` and then
`LSC Distribution Location."Skip Repl. Counter Update"`. When that flag is true the trigger exits before the FindLast
and no lock is taken. The decision is cached per session under the session key `#REPLCOUNT`, so POS and web sessions
must log in again after changing it. If Retail Setup has no Distribution Location, the code defaults to maintaining
counters.

**Before switching it off** confirm nothing consumes the counters: Data Director "by counter" replication, LS Central
Web Replication (OData pull used by mobile apps, monitor page 10012608), scheduler sub-jobs. Related setup:
`LSC Retail Setup."Std. Trans. Repl. Cntr. Valid."` and table `LSC Transaction Header Repl. Count` handle the
transaction-header variant separately.

`LSC POS Functions.RecalcSlip*` showing up with a few seconds of lock on `LSC POS Trans. Line` is a different thing:
it only locks the current receipt's own lines during a heavy recalculation (coupons, quantity change) and does not
block other terminals.
