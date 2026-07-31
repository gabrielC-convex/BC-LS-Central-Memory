---
name: report-excel-layout-data-table
description: A BC Excel report layout binds by the header-cell text, which must equal the dataset column names and stay in sync with the sheet's 'Data' table definition — opening one in Excel to reorder columns corrupts that binding
tags: [report, excel, layout, al, troubleshooting]
metadata:
  type: reference
provenance: observed
verified: 2026-07-31
---

A BC Excel report layout is a one-row workbook: a sheet named `Data` whose header cells carry the
**dataset column identifiers** (the `column(Name; Source)` names, not the captions), wrapped in an
Excel *table* also named `Data`.

Editing one in Excel is what breaks it. Excel rewrites the table definition, and the layout then
either loses columns silently or fails to bind. Edit it programmatically instead, and keep three
things in sync in the same operation:

1. the header cells in row 1,
2. the table's `tableColumns` list,
3. the table's `ref` range, which must shrink or grow with the column count.

With openpyxl, rewriting a table means removing and re-adding it — mutating `tableColumns` in
place does not survive the save:

```python
ws = wb["Data"]
tbl = list(ws._tables.values())[0]          # exactly one table, named Data
names = [c.name for c in tbl.tableColumns]  # these ARE the dataset column names
...
del ws._tables[tbl.name]
new = Table(displayName=tbl.displayName, name=tbl.name,
            ref=f"A1:{get_column_letter(len(names))}1")
new.tableStyleInfo = tbl.tableStyleInfo
ws.add_table(new)
```

Renaming a column is therefore a two-sided change: the AL `column()` name and the header cell must
match, or that column stops appearing in the export.

**Why:** the corruption is silent. The file still opens, the report still runs, and columns simply
go missing from the output — usually noticed by whoever consumes the export, long after the edit.

**How to apply:** treat report `.xlsx` layouts as source code, not spreadsheets: never open them in
Excel to "just reorder something". Script the change, then dump the table columns back out and
compare against the AL dataset before shipping.
