---
name: customer-order-header-exclude-collect-ship-internal-fields
description: LS Central 28 adds two internal Boolean fields to the Customer Order header - Exclude Collect (123) and Exclude Ship (124) - that are on no page and have no help page; they do not exist in 27.0.24, so a search in older symbols or source reports them as missing
tags: [fields, version, symbols, alpackages, tooltip, retail, misleading]
metadata:
  type: reference
provenance: observed
verified: 2026-10-13
---

`LSC Customer Order Header` (table 10016651) tells a collect-in-store order from a ship-to-address
order with **`Ship Order`** (field 126, Boolean; the Ship-to address block is 127-136, the shipping
agent 139). From LS Central 28 the header also carries two flags that can rule one of the two
variants out for an order:

| Field | Name | Tooltip in the symbols |
|---|---|---|
| 123 | `Exclude Collect` | Internal field to indicate if the order is excluded from collect options. |
| 124 | `Exclude Ship` | Internal field to indicate if the order is excluded from shipping options. |

Checked in the symbol packages of **28.1.0.1807** and **28.2.12.4105**: both fields are there, both
Boolean. They are "internal" in the literal sense:

- no page and no page extension of LS Central shows them (no control is bound to either);
- the help site's field reference has no page for them - it has pages for 120 and 127-139 of this
  table and skips 121-126, `Ship Order` included, even though the fields carry tooltips;
- the symbols give no method signature that names them, so *who* sets them cannot be read without
  the method bodies of version 28.

In **27.0.24** they do not exist: the header's field list goes 120, 121, 125, 126, 127.

Do not confuse them with their neighbours, which exist in every version and mean something else:

- `Collection by Exclusion` (`LSC Customer Order Setup`, field 12) - whether the Collect panel on the
  POS opens with all lines pre-selected; mirrored on the header as `CollectionByExclusion(int)` (10004);
- `Will Ship Orders` (5) and `Orders can be Collected` (6) on `LSC CO Sourcing Locations` - what a
  sourcing location is allowed to do, defaulted from the Location card.

Why it misleads: the usual offline sources - the symbol packages a project compiles against and an
extracted source tree - are often a major version behind the environment. A search there for
"Exclude Collect" returns nothing, the help returns nothing either, and the tempting conclusion is
"the field does not exist". It does; the evidence was simply older than the system.

How to apply:
- "this field / event / procedure does not exist" is a claim about one version; state the version,
  or check the symbols of the version that actually runs before saying it;
- a production environment does not hand symbols over its dev endpoint, a sandbox on the same
  version does - download the vendor's package from there into a scratch folder (never into the
  folder the compiler reads) and read `SymbolReference.json` from it;
- field tooltips are in the symbols even when the help has no page for the field - for LS Central
  fields the tooltip is often the only documentation.

Related: [[pos-run-objects-and-commands]] (another rule that lives only in a field tooltip).
