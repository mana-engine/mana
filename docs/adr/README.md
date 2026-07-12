# Architecture Decision Records

One file per decision: `NNNN-title.md` (zero-padded, incrementing). Each records
**context**, **decision**, and **consequences**. Write an ADR whenever a design
decision arises — a new dependency, a module boundary, a file-format change — and
reference it in the commit that acts on it.

Use `/adr <title>` to scaffold a new numbered record from the template.

The mandatory scripting-API ADR (ADR 0003) is **accepted** — `src/script` may be
built to that contract (as its own task that adds the ziglua dependency).

| ADR | Title | Status |
|-----|-------|--------|
| 0001 | ECS: minimal custom over zflecs | accepted |
| 0002 | Native dependencies deferred; ports ship as stubs | accepted |
| 0003 | Lua scripting API: table shape, events, handles, versioning | accepted |
| 0004 | Scene/entity component schema + ECS storage model | accepted |
| 0005 | File-watch port + hot-reload model | accepted |
| 0006 | Rendering: Vulkan gpu backend, offscreen-first | accepted |
