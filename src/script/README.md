# src/script

**Responsibility:** Lua 5.4 integration via ziglua. Lua decides *what* happens
(abilities, AI decisions, encounter/dialogue/UI logic); the engine executes *how*.
Lua never iterates all entities per frame — the engine dispatches events
(`on_spawn`, `on_hit`, `on_death`, `on_collision_begin`, `on_room_enter`, timers)
and Lua sets data the engine consumes. Script dispatch is Tracy-zoned and budgeted.

**Status.** ADR 0003 (accepted) fixes the `mana` API table, event list, opaque
handle semantics, versioning, sandbox, and error policy. Implemented so far,
gated behind `-Denable-lua`:
- The sandboxed per-script `_ENV` (`lua.zig`: `State`, `pushSandboxEnv`).
- The `mana` v1 table's implementable-without-live-Sim subset — `version`,
  `log`, `is_valid` — and the opaque entity-handle pack/unpack ABI
  (`handle.zig`, `mana.zig`).

**Not yet implemented** (needs an engine → script wiring task first — nothing
here reaches a live `Sim`/`World`): `position`, `set_velocity`, `get`, `set`,
`spawn`, `despawn`, `after`, `every`, `cancel`, `now`, `random`, `random_int`,
and event dispatch (`on_spawn`/`on_hit`/etc.).

**May import:** `core`, `std` (and `zlua`, under `-Denable-lua`).

**Imported by:** `engine` (once the engine → script wiring task lands).
