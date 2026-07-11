# src/data

**Responsibility:** The file layer that makes files the source of truth — comptime
ZON serializer/reflection, file watching, and hot reload. Its round-trip
guarantee `parse(serialize(x)) == x` is the backbone of the architecture and must
never regress.

**May import:** `core` (and `std`). Nothing above.

**Imported by:** `engine`, `runtime`, `tools`.
