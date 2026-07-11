# src/script

**Responsibility:** Lua 5.4 integration via ziglua. Lua decides *what* happens
(abilities, AI decisions, encounter/dialogue/UI logic); the engine executes *how*.
Lua never iterates all entities per frame — the engine dispatches events
(`on_spawn`, `on_hit`, `on_death`, `on_collision_begin`, `on_room_enter`, timers)
and Lua sets data the engine consumes. Script dispatch is Tracy-zoned and budgeted.

**Deferred stub.** No scripting API table may be added until the mandatory ADR
defining its shape (event list, opaque handle semantics, versioning) is written —
it is the most important interface in the project.

**May import:** `core`, `std` (and ziglua, once wired).

**Imported by:** `engine` (once the API ADR is approved).
