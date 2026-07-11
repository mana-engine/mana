# src/ecs

**Responsibility:** Minimal custom entity-component-system. Entities are dense
IDs; components are plain data in contiguous SoA arrays; systems are free
functions iterating in cache order. No objects-with-behavior, no virtual dispatch
in loops, no observer patterns in the hot path. (See `docs/adr/0001` — custom over
zflecs; swappable behind the same shape later if profiling demands it.)

**May import:** `core` (and `std`). Nothing above.

**Imported by:** `engine`.
