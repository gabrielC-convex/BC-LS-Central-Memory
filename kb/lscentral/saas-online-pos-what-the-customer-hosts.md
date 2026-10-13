---
name: saas-online-pos-what-the-customer-hosts
description: In the LS Central SaaS Online POS architecture two components are not part of Microsoft's BC SaaS and are hosted by the customer in their own Azure - the Commerce Service (called Commerce Server on the diagram; ScanPayGo reaches BC through it) and the Update Service (delivers app updates to the POS terminals). The help page states only half of this in text; the rest is in its diagram
tags: [saas, pos, retail, documentation, misleading]
metadata:
  type: reference
provenance: vendor-docs
verified: 2026-10-13
---

Source: the help page *LS Central SaaS Architecture* (Implementation Guide), section *Online POS*,
text and diagram `Architecture_a.PNG`.

What the customer hosts in their own Azure, next to Microsoft's BC SaaS:

| Component | Its role | Where the help says it |
|---|---|---|
| **Commerce Service** ("Commerce Server" on the diagram) | The link between **ScanPayGo** and the Business Central environment. It is a Windows service under IIS, so it cannot live inside BC SaaS; in SaaS it is installed in "WS mode" and reads LS Central only through web services | hosting: **diagram only** - the text says just "ScanPayGo operates via the Commerce Service" |
| **Update Service** | Installs **Hardware Station** and **AppShell** on the POS machines and delivers their application updates, keeping them in step with the updates in SaaS (the "App updates" arrow to the Online POS) | text: "The Update Service is hosted by the customer in Azure (recommended)" |

Everything else on the diagram connects **directly** to the environment in BC SaaS: the web store,
the hand-held Mobile Inventory, the Online POS terminals and the mobile POS devices. All POS
terminals work online against **one Business Central company**; the data is in the Azure SQL
database of the environment.

Two precisions the short version loses:

- for the Update Service the help says Azure hosting is *recommended*, not mandatory - what is
  fixed is that the customer hosts it, not Microsoft;
- the same page describes two more Online POS layouts (distributed companies, distributed
  environments) and two Offline POS layouts; the two customer-hosted components are the same in
  the online ones.

Why it misleads: a search of the page's text finds the Update Service sentence and concludes there
is one customer-hosted component. The second one, the list of devices that connect directly, the
single company and the Azure SQL box are drawn, not written. On architecture pages of the help,
read the diagram before answering - the text under it is a commentary, not a transcript.

How to apply:
- when sizing a SaaS project, count two things outside the BC subscription: an Azure host for the
  Update Service, and one for the Commerce Service if ScanPayGo (or another consumer of the
  eCommerce API) is in scope;
- Mobile Inventory and a Magento web store need neither: they call the SaaS environment directly.
