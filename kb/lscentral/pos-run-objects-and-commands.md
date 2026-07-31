---
name: pos-run-objects-and-commands
description: A POS button can open any BC object — including a Codeunit — via the RUNOBJ command and a POS Run Objects row; Run Codeunit on a POS Command is honoured only when Function Type is POS External, which is why built-ins like PRINT_Z show Run Codeunit = 0
tags: [pos, retail, runobject, actions, buttons, al, extension]
metadata:
  type: reference
provenance: observed
verified: 2026-07-31
---

Two independent ways exist to put custom behaviour behind a POS button, and picking the wrong
one wastes a deployment cycle.

## How do I open a page, report or codeunit from a POS button without writing code?

Use the built-in **`RUNOBJ`** command plus a row in table **99008926 "LSC POS Run Objects"**
(list page: *POS Run-Objects*). Its only fields are `Object Code`, `Object Type`, `Object ID`,
`Manager Key`, `Modal`.

`Object Type` is an Option whose members are ` , , , Report, XMLport, Codeunit, , , Page` —
so **Codeunit is supported**, not just Page. The button then carries `Command = RUNOBJ` and
`Parameter = <Object Code>`. `Object Code` is `Code[10]`; the `Object Name` FlowField filling in
after you type the ID is the confirmation that it resolved.

A run-object row **cannot carry a filter or a parameter**. Opening a specific record or a
filtered list therefore needs a codeunit that applies the filter itself and opens the page.

`Manager Key` on the row gates the button behind a manager login — the place to restrict a
button that reaches destructive operations.

## Why does Run Codeunit do nothing on my new POS Command?

Table **99008920 "LSC POS Command"** has `Function Type` with members
`POS Internal, POS External, POS Action`. Per the field's own tooltip, `Run Codeunit` applies
**only to External commands**. LS Retail's own commands are `POS Internal` and consequently show
`Run Codeunit = 0` — copying that shape for a custom command produces a button that does nothing.
A custom command that must run your codeunit needs `Function Type = POS External`.

## Which event fires when a POS button is pressed?

`LSC POS Controller` publishes
`OnPOSCommand(var ActivePanel: Record "LSC POS Panel"; var PosMenuLine: Record "LSC POS Menu Line")`.
Match on `PosMenuLine.Command`. The button itself is a row in `LSC POS Menu Line` (99008906),
whose `Command` field is `Code[20]` pointing at `LSC POS Command`.

Codeunits meant to be run from a POS button are declared with
`TableNo = "LSC POS Menu Line"` — seeing that property on a vendor codeunit is a strong signal it
is POS-facing, but it does **not** prove its `OnRun` does anything: symbol packages carry
signatures, never trigger bodies. A panel *controller* codeunit has the same shape and an `OnRun`
that is not the entry point, so pointing RUNOBJ at one produces a button that silently does
nothing — no panel, no error.

**Why:** the three mechanisms look interchangeable from the configuration UI, and the failure
mode of the wrong choice is silence rather than an error message.

**How to apply:** try RUNOBJ first — it needs no code and no deployment. Fall back to a custom
`POS External` command with `Run Codeunit`, or to an `OnPOSCommand` subscriber, only when the
target has no runnable entry point. When a vendor exposes the behaviour you want as an
`internal` method, none of these can reach it (see [[al-internal-blocks-extension-reuse]]) and
the honest answer is to open the vendor's page instead.
