# src/data

**Responsibility:** The file layer that makes files the source of truth — comptime
ZON serializer/reflection, file watching, and hot reload. Its round-trip
guarantee `parse(serialize(x)) == x` is the backbone of the architecture and must
never regress.

**May import:** `core` (and `std`). Nothing above.

**Imported by:** `engine`, `runtime`, `tools`.

`zon.serialize` is a comptime reflection walk, so a Zig type describes the object it
writes — field names included. `zon.Object(V)` is the escape hatch for the one shape
that cannot: an object whose **field names are runtime data**, like `input.zon`'s
`.actions` table (ADR 0040 §3), whose names *are* the content-declared action names and
so are unknown to `src/**` (invariant #6). It writes an ordinary `.{ .<name> = <value>,
… }` literal — no new dialect, byte-identical to the equivalent struct's output — and is
the write-side counterpart of the hand-rolled `Zoir` walk `engine/action_parse.zig`
already needed on the read side. Names are emitted verbatim, so the caller checks
`std.zig.isValidId`.
