# 0003. Lua scripting API: table shape, events, handles, versioning

- Status: accepted
- Date: 2026-07-12

## Context

Lua 5.4 (via ziglua) is the engine's scripting layer (ADR 0002 defers the ziglua
dependency itself; this ADR defines the *interface* it will expose, which the
vision names "the most important interface in the project" and requires an ADR
before any `src/script` code lands).

Hard constraints from the vision that this API must encode:
- **Lua decides *what*; the engine executes *how*.** Scripts are event-driven and
  rule-shaped, never per-entity-per-frame.
- **Scripts never iterate all entities per frame.** The engine dispatches events;
  scripts respond by reading/writing data the engine consumes.
- **Prefer data over Lua.** The API is for genuinely bespoke logic; anything
  expressible as a ZON definition stays in data.
- **Opaque entity handles, never raw pointers.** Handles must survive despawn
  safely (detect use-after-free) and must never be persisted to disk.
- **One small, versioned surface.** Every future addition needs its own ADR.
- **Budgeted.** Dispatch is Tracy-zoned with a per-frame time budget; sustained
  overrun is the objective trigger to promote a system to native.

## Decision

### 1. Script module shape

A script is a Lua module that **returns a table of event handlers**. The engine
loads it once, caches the table, and dispatches by key lookup (a missing key means
"no handler" — the cheap, common case). No global handler-name convention, no
namespace pollution.

```lua
-- games/sandbox/scripts/exploding_barrel.lua
return {
  on_spawn = function(self)
    mana.log(.info, "barrel spawned")
  end,
  on_death = function(self, ev)
    mana.spawn("explosion", mana.position(self))
  end,
}
```

Content (ZON) attaches a script to a prototype/ability/room by path, e.g.
`.script = "scripts/exploding_barrel.lua"`. The wiring format is content and will
be pinned by the scene/entity-schema ADR — not here.

### 2. The `mana` API table

Every script environment receives a single global table `mana`. It is the entire
surface; nothing else engine-side is reachable from Lua. Initial v1 surface (kept
deliberately minimal — grow only via new ADRs):

**Introspection**
- `mana.version` → integer API version (currently `1`).

**Entities (all take/return opaque handles)**
- `mana.is_valid(h)` → bool — false after despawn (generation check).
- `mana.position(h)` → `x, y, z` (three numbers).
- `mana.set_velocity(h, x, y, z)`.
- `mana.get(h, component)` → value — reads a named data component (data-driven;
  the component set is defined by the entity schema, not hard-coded here).
- `mana.set(h, component, value)`.
- `mana.spawn(prototype, x, y, z)` → handle — queues a spawn; resolves next tick.
- `mana.despawn(h)` — queues a despawn.

**Timers (the sanctioned alternative to per-frame callbacks)**
- `mana.after(seconds, fn)` → timer handle — one-shot.
- `mana.every(seconds, fn)` → timer handle — repeating.
- `mana.cancel(timer)`.

**Deterministic environment** (replaces the stdlib facilities the sandbox removes)
- `mana.now()` → number — current **sim** time in seconds (tick-derived, not wall
  clock). Deterministic; `os.time`/`os.clock` are not exposed.
- `mana.random()` → number in `[0, 1)` and `mana.random_int(lo, hi)` → integer —
  drawn from the sim's seeded RNG (`core.Rng`), so runs are reproducible.
  `math.random`/`math.randomseed` are removed for this reason.

**Diagnostics**
- `mana.log(level, msg)` — `level` is an enum-like literal (`.info`/`.warn`/`.error`).

Mutations (`set_velocity`, `set`, `spawn`, `despawn`) are **deferred and
transactional**: each records intent into a per-invocation command buffer that the
engine applies at a defined point in the tick. A script can never observe a
half-updated world or invalidate an in-flight iteration — and if a handler errors
mid-way, its whole buffer is discarded (see §9), so partial effects never land.

### 3. Engine → script events (v1)

The engine calls these handler keys if present. Every payload is a plain Lua table
of scalars and opaque handles — never an engine pointer.

| Handler | Signature | Fired when |
|---|---|---|
| `on_spawn` | `(self)` | entity enters the sim |
| `on_hit` | `(self, ev)` — `ev = { other, amount, kind }` | entity deals/takes a hit |
| `on_death` | `(self, ev)` — `ev = { killer }` | entity's HP-equivalent reaches 0 |
| `on_collision_begin` | `(self, ev)` — `ev = { other, normal_x, normal_y }` | physics trigger/overlap starts |
| `on_room_enter` | `(self, ev)` — `ev = { room }` (room script) | room becomes active |
| timer callbacks | `()` | via `mana.after`/`every` |

**There is deliberately no `on_update`.** A per-entity-per-frame Lua callback is the
anti-pattern the vision forbids; periodic needs use timers, and truly hot needs get
promoted to native.

### 4. Handle semantics

- A handle is an **opaque generational id**: a `u32` index + `u32` generation,
  packed into one Lua 5.4 integer (64-bit). Scripts treat it as a token: no
  arithmetic, no comparison beyond equality, no serialization.
- `is_valid` compares the packed generation to the live slot; a stale handle
  (entity despawned, slot reused) reads as invalid, and every accessor returns a
  safe error/nil rather than touching freed memory.
- **Handles are runtime-only** and must never be written to a save file or ZON.
  Persistent references use stable content ids, resolved to handles at load.

### 5. Versioning policy

- `mana.version` is an integer, starting at **1**.
- The surface is **additive** within a version; a content package declares the
  version it needs (e.g. `.script_api = 1` in `game.zon`), and the runner refuses
  to load a package requesting a version the engine does not provide.
- **Any** change to the surface — new function, new event, changed signature or
  payload, changed handle representation — requires its own ADR. Removals or
  breaking changes bump the integer.
- The handle bit-layout is part of the ABI and changes only with a version bump.

### 6. Budget & measurement

- All script dispatch for a frame runs inside a single Tracy zone with a per-frame
  budget (initial target: **0.5 ms/frame**, tunable via a build/config option).
- Overruns are counted and logged; a system that consistently exceeds budget is the
  objective, measured trigger to promote it to native — not a judgment call.

## Consequences

- **Easier:** the interface is tiny, explicit, and safe (opaque handles, deferred
  mutations, no per-frame callback); content authors get a predictable event model;
  the version gate makes engine/content compatibility a hard, checkable contract.
- **Harder:** every capability scripts need must be added deliberately (new ADR),
  which is friction by design — it forces "can this be data instead?" first.
- **Committed to:** implementing this exact surface when `src/script` is built
  (a separate task that adds the ziglua dependency, which needs its own go-ahead).
  The `game.zon` `script_api` field and the `.script` attach-point are dependencies
  on the forthcoming scene/entity-schema ADR; timers and deferred spawn/despawn
  imply an engine-side command buffer and timer wheel that must exist before the
  first script runs.

### 7. Sandboxing — allowlisted environment

Scripts run in a per-script `_ENV` that is an **allowlist**, never the full globals
with dangerous bits removed. `_ENV` contains only:

- A curated **base** subset: `pairs`, `ipairs`, `next`, `select`, `type`,
  `tostring`, `tonumber`, `assert`, `error`, `pcall`, `xpcall`, `setmetatable`,
  `getmetatable`, `rawget`, `rawset`, `rawequal`, `rawlen`, `#`/operators. **Not**
  `load`/`loadfile`/`dofile` (arbitrary code), `collectgarbage`, or raw `print`
  (`print` is aliased to `mana.log(.info, …)`). The sandbox's `getmetatable`
  intentionally returns `nil` for **string** arguments: the primitive string
  metatable is shared process-wide and its `__index` is the master `string`
  table, so exposing it would let one script `rawset` into it and corrupt
  `string.*` for every sibling on the same `lua_State`, breaking the §8
  isolation guarantee. `getmetatable` remains fully functional for tables and
  userdata.
- `string`, `table`, `coroutine`, `utf8` — safe and deterministic. Each script
  receives its **own copy** of these library tables (and of `math`) in its
  `_ENV`, so one script mutating a library entry cannot affect a sibling (§8).
- `math` **minus** `random`/`randomseed` (those are nondeterministic global state;
  use `mana.random`). Transcendental libm results are the sim's determinism
  responsibility, not the sandbox's — scripts make discrete decisions, not hot-path
  continuous math.
- The `mana` table.

**Removed entirely:** `os`, `io`, `debug` (as script-visible; `debug.traceback` is
used engine-side only for error reports), and `package`/`require`. Cross-file
composition within a content package (a VFS-scoped `require`) is a **later ADR**;
v1 scripts are flat single files. This makes an untrusted mod script unable to
touch the filesystem, network, wall clock, or process — closing the mod threat
surface and protecting determinism.

### 8. Lua state granularity & hot reload

- **One `lua_State` per sim instance** (per world), not per game and not per
  script. This is required for determinism: the determinism test runs two sims that
  must not share Lua global state, and a fresh sim must start from a clean slate.
  Each script module loads into its own sandboxed `_ENV` within that state, so
  scripts are isolated from each other while sharing one scheduler for
  timers/coroutines.
- **Durable state lives in engine components (data), not Lua globals.** Scripts are
  effectively stateless between events; anything that must persist is written via
  `mana.set` into an entity component. This is the "prefer data" rule made concrete
  and is what makes hot reload trivial.
- **Hot reload of a changed script:** re-evaluate the module source → produce a new
  handler table + fresh `_ENV` → **atomically swap** it in. Timers registered by the
  old version are **cancelled** (their closures are stale); new handlers re-register
  as their events fire. Lifecycle events are **not** retroactively re-fired. Because
  durable state is in components, no migration dance is needed.

### 9. Error policy — transactional, log-and-continue, circuit-breaker

- Every handler call is wrapped in `pcall`. On error: the engine logs the message
  with an engine-side `debug.traceback`, **discards that invocation's command buffer**
  (§2, so no partial mutations land), and the sim **continues**. A content bug never
  crashes the engine core.
- **Circuit breaker:** after N errors (initial N = 8) from the same handler within a
  window, that handler is **disabled** (stopped being called) with a prominent log;
  other handlers on the same entity and its component data keep working. A hot
  reload of the script re-enables it. Disabling a handler — not the whole entity, and
  never the sim.
- This is fully deterministic (same inputs ⇒ same error ⇒ same disable at the same
  tick), so it does not perturb the state hash; log output is a side channel,
  excluded from the hash like VFX.

## Deferred to the implementation task (minor, non-blocking)
- Exact tick phase where the command buffer is flushed (before/after physics), pinned
  when the engine tick has those phases.
- VFS-scoped `require` for multi-file script packages — its own ADR when needed.
- Tuning of the budget (0.5 ms), circuit-breaker N (8), and window — all config, not
  interface.
