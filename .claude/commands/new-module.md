---
description: Scaffold a new src/ module (dir + README + test block) and wire it into build.zig.
argument-hint: <module-name> [imports: core,data,...]
---

Scaffold a new engine module named **$ARGUMENTS**.

Before writing, confirm where the module sits in the import DAG (see CLAUDE.md) —
it must not create an upward or cyclic dependency. If placement is ambiguous, ask.

Steps:
1. Create `src/<name>/<name>.zig` with:
   - A top `//!` module doc comment stating its single responsibility and what it
     may import.
   - Imports only for the modules you confirmed (plus `std`).
   - A minimal `pub const` surface and at least one `test` block by behavior name.
2. Create `src/<name>/README.md` stating responsibility, "may import", and
   "imported by", matching the style of the existing module READMEs.
3. Wire it into `build.zig`:
   - Add a `b.createModule(...)` for it with `.target`/`.optimize`.
   - Add its `addImport(...)` edges (both its dependencies and any module that
     should now import it).
   - Add it to the `tested` array so its tests run under `mise run test`.
4. Run `mise run check` and report the actual output. Do not commit unless asked.

If this is a new **port** (an edge abstraction like gpu/platform), also state the
comptime adapter-selection story and whether it needs a build option — and note
that a load-bearing new abstraction wants an ADR (`/adr`).
