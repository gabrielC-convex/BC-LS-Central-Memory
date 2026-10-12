---
name: store-location-table-multiple-locations-per-store
description: A store can own several BC locations through the standard table LSC Store Location (10001416); registering a location there is what makes it selectable on retail picking/receiving headers and store inventory worksheets, because every store-scoped location field validates through StoreLocationOk → Store.FindStore
tags: [retail, warehouse, fields, pages, posting, silent-failure]
metadata:
  type: reference
provenance: observed
verified: 2026-09-07
---

LS Central models "a store owns more than one location" with the table **LSC Store Location**
(10001416), edited from the Store Card action "Store Locations" (page 10001415). Primary key =
Store No. + Location Code; flags `Sales Location` and `Special Order Location`; the older
`Claim Location` field is `ObsoleteState = Removed`. The primary location stays on
`LSC Store."Location Code"` — the Store Card is not touched.

Why the row matters: every store-scoped location field — Retail Picking / Retail Receiving header
`Location Code` (P/R Counting Header), Store Inventory Worksheet `Location Code` / `New Location Code`,
Retail User location — validates through `LSC BO Utils.StoreLocationOk → LSC Store.FindStore`, which
accepts a location only if it is the store's primary or a row in LSC Store Location, otherwise errors
"Location X not found in store Y". `FindStore` checks LSC Store Location **first**, then the primary.
Nothing in LS Central inserts rows automatically (verified in source, LSC 27.0.24).

Traps observed while planning a secondary "non-saleable" location per store:

- The lookup on those fields (`BO Utils.LookupLocation`) lists **only** the Store Location rows —
  after registering the secondary location the dropdown shows it and not the primary. Typing the
  primary code still validates. Never add the primary itself as a Store Location row: the Store
  table rejects a primary that is present in Store Location.
- `Sales Location = false` does **not** mean "non-saleable" to LS Central: the flag only drives the
  SOAP inventory lookup (GetItemInventory); every other path treats any Store Location row as
  ordinary store stock. Classify secondary locations with an explicit custom flag, never with this
  one and never by naming convention.
- A location flagged `LSC Location is a Warehouse` is refused as a Store Location row. Uniqueness is
  enforced across stores ("Location %1 is related to store %2").
- The POS inventory lookup (Inventory Lookup Table) is keyed per store on the **primary** location
  only, and Location Profiles group stores, not locations — a secondary location is invisible at the
  POS. Exception: the web-service `GetInventoryMultiple V2` sums all Store Location rows regardless
  of `Sales Location`.
- Automatic replenishment only considers a location that is some store's primary and flagged
  `LSC Active for Autom. Replen.` — a secondary location is excluded by construction.
- Provisioning needs only: Location card → Inventory Posting Setup rows per (location, inventory
  posting group) (a hard Get in Inventory Posting To G/L; missing row = first posting fails, with
  or without Automatic Cost Posting) → LSC Store Location row. No Distribution Location, Store
  Group, In-Transit or new General Posting Setup is involved. RapidStart order: 14 → 5813 → 10001416.
- `Location.Code` is Code[10]: an 8-digit store number leaves two characters for a suffix.
