---
name: al-internal-blocks-extension-reuse
description: A public-looking method in a dependency can still be internal, and symbol browsers usually do not show it — you discover it as AL0161 at compile time, after designing around a call you cannot make
tags: [al, extension, dependency, symbols, symbolreference, troubleshooting, misleading]
metadata:
  type: reference
provenance: observed
verified: 2026-07-31
---

Methods in a dependency app can be `internal`, and an app grants access to them only through an
explicit `InternalsVisibleTo` entry. Calling one from your extension fails at compile time:

```
AL0161: '<Method>()' is inaccessible due to its protection level
```

The trap is discovering this late. In `SymbolReference.json` the access modifier is a per-method
flag — `"IsInternal": true` — sitting alongside `IsLocal` and `Attributes`. A tool that prints
method names and signatures shows an internal method exactly like a public one, so a method can
look perfectly callable right up to the build. Check three things before designing around a
dependency call:

- the method's own `IsInternal` flag,
- the enclosing object's `Properties` for `Access = Internal` (which makes every member
  unreachable regardless of the per-method flags),
- the app's top-level `InternalsVisibleToModules` — empty means nobody is granted access.

**Verified 2026-07-31:** a vendor codeunit exposed a method that opens a POS panel, with the
correct `TableNo` shape for a POS handler and integration events published around it. Both the
method and its sibling on a second codeunit were `IsInternal: true`, and the app declared no
`InternalsVisibleTo`. No configuration route and no code route existed; the workable answer was
to open the vendor's own page instead of reproducing the behaviour.

**Why:** an internal method is invisible as such in most symbol tooling, so it survives design
and review and fails at the build — after the approach has been chosen and sometimes after a
version was cut for it.

**How to apply:** when a plan depends on calling into a dependency, compile a three-line stub
that just calls the method *before* building anything around it. If it is internal, the options
are: use an integration event the vendor publishes, drive the vendor's own UI, or ask the vendor
to widen the access — reimplementing their internals is rarely the cheap path it looks like.
