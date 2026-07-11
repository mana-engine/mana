# Architecture Decision Records

One file per decision: `NNNN-title.md` (zero-padded, incrementing). Each records
**context**, **decision**, and **consequences**. Write an ADR whenever a design
decision arises — a new dependency, a module boundary, a file-format change — and
reference it in the commit that acts on it.

Use `/adr <title>` to scaffold a new numbered record from the template.

**Mandatory ADR before any scripting work:** the shape of the Lua API table (event
list, opaque handle semantics, versioning policy).

| ADR | Title |
|-----|-------|
| 0001 | ECS: minimal custom over zflecs |
| 0002 | Native dependencies deferred; ports ship as stubs |
