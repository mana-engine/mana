# 0024. `mana.get`/`mana.set`: named scalar data components

- Status: proposed
- Date: 2026-07-13

## Context

ADR 0003 §2 promises `mana.get(h, component)` → a named per-entity value and
`mana.set(h, component, value)` → write one. These are the last two members of the
fixed v1 `mana` surface still unimplemented: `host.zig` and `mana.zig` carry them
only in comments, and ADR 0015 §1 reserved them as vtable entries but left the
storage undecided ("`get` — named data components — needs a data-component store").
This is that store plus the two accessors, the final slice that completes the ADR
0003 §2 table.

The single real decision is **how to store arbitrary named per-entity data while
honoring the DOD invariant** (CLAUDE.md: "components are plain data in contiguous SoA
arrays; systems are free functions in cache order — no per-entity behavior objects").
A named-component store is exactly the kind of feature where a naive design quietly
violates that invariant.

Two forces are in tension:
- **"Arbitrary named"** (ADR 0003 §2's wording) pulls toward a per-entity dynamic
  map — maximum flexibility, a script can invent a key at runtime.
- **DOD / files-are-source-of-truth / "prefer data over Lua"** (CLAUDE.md) pull
  toward a fixed, declared, columnar set the engine can iterate cache-coherently and
  hash deterministically — the same shape every built-in component already has.

## Decision

### Storage — Option B: registered named columns (dense SoA per name)

A **`DataComponents`** store (`src/engine/data_components.zig`) lives in the `World`
alongside the built-in component columns. It holds, in parallel and in registration
order:
- `names: [column id → owned name]` — the declared data-component names, and
- `columns: [column id → SparseSet(f64)]` — one dense sparse-set column per name,
  keyed by entity index, exactly like `World.transforms`/`healths`.

A name is **registered** (its column allocated) when it first appears in **data**: a
scene `EntityDef` or an entity prototype (ADR 0016) may declare
`.data = .{ .{ .name = "hp", .value = 3 }, … }`, and `scene.load` /
`CommandBuffer` bundle-attach register each name and set its value. Reads and writes
after that resolve the name to a stable column id (an append-only index — columns are
never removed, so an id is valid forever once handed out).

The options weighed:

- **Option A — dynamic per-entity map** (a `name → value` hashmap per entity).
  Maximally flexible and a literal reading of "arbitrary named": a script could
  `set` any key at any time with no prior declaration. **Rejected** — it violates the
  SoA/DOD invariant this project is built on: per-entity heap allocation, pointer-
  chasing on every access, no cache-coherent iteration for a future native system,
  and a non-obvious deterministic hash order (map iteration order). It optimizes for
  a flexibility no game has asked for at the cost of the core invariant.

- **Option B — registered named columns** (chosen). DOD-friendly (each name is a
  dense column a native system can iterate in cache order), deterministic (columns in
  registration order, values in dense order — the exact pattern `World.stateHash`
  already hashes), and files-first (the set of names is **declared in ZON data**, the
  hot-reloadable source of truth, not invented in imperative script). The honest cost:
  **a name must be declared in data before a script can `set` it** — the store is not
  a runtime-arbitrary key/value bag. A `set` to an undeclared name is a content bug
  (logged and dropped), not a silent auto-registration.

The tradeoff is deliberate. "Arbitrary named" in practice means "the game author
names the components," and a game author writes ZON — so a declared set loses nothing
a real game needs while keeping the store inside the DOD invariant. If a genre ever
genuinely needs runtime-arbitrary keys (e.g. a scripting-heavy sandbox that mints
component names from player input), that is a **new ADR**: it would add a distinct
dynamic-key store *behind the same `get`/`set` seam* — the `mana` surface and host
vtable defined here do not change, only a second backing store slots in. We do not
build that speculative flexibility now (CLAUDE.md: "no speculative flexibility;
second concrete impl planned, or don't abstract").

### Value type — `f64` scalar only

A data-component value is a single **`f64`**, matching Lua 5.4's number type exactly
(no lossy round-trip through the seam). `mana.get` returns a Lua number; `mana.set`
takes one. Richer value types (vectors, strings, booleans, tables) are **explicitly
deferred to their own ADR** — the first games (Snake → Pac-Man → Tetris) need scalar
per-entity attributes (score, energy, a state tag encoded as a number), nothing
richer. A scalar store keeps the column type uniform and the state hash trivial.

### Accessors (ADR 0015 host seam)

- **`get(handle, name)` — immediate read**, like `position`/`now`. Resolves `name`
  to a column id against the live world and returns the entity's value, or **`nil`**
  when: no Sim is dispatching, the handle is stale/forged, the entity has no value in
  that column, or **`name` is not a declared data component**. An undeclared name is
  `nil`, never a raised error — a script can probe optimistically.
- **`set(handle, name, value)` — deferred mutation**, like `set_velocity`/
  `set_position`. Resolves `name` to a column id immediately; if the name is
  **undeclared**, the write is dropped with an engine-side warning (never a crash,
  never a mid-dispatch content error that would roll back the whole handler over a
  typo). Otherwise it queues a `set_data{entity, column, value}` on the command buffer,
  applied at the next flush. A stale handle is dropped at flush; with no Sim
  dispatching it is a no-op. Fire-and-forget, returns nothing.

`name` crosses the seam as a `[]const u8` borrowed only for the call — `set` resolves
it to a column id and queues the *id*, never the string, so no Lua-owned string
outlives the call.

### Determinism

The store is **sim state** and enters `World.stateHash`, hashed in a fixed order:
for each column in registration order, the name bytes, then the dense entity indices,
then the dense `f64` values (the same dense-order fingerprint the built-in columns
use). A scene that declares **no** data components has an empty store, which
contributes **zero bytes** to the hash — so the pinned determinism golden
(`tests/determinism.zig`, a data-component-free scene) is **bit-identical** to before
this ADR. `set` flows through the existing deterministic command buffer with ADR 0003
§9 rollback; nothing nondeterministic is introduced.

## Consequences

- **The ADR 0003 §2 `mana` table is complete.** `get`/`set` were the last deferred
  members; after this every v1 accessor is wired, and `src/script/CLAUDE.md`'s
  "still deferred" list is empty.
- **Content gains per-entity scalar state** (score, energy, cooldown, a numeric
  state tag) declared in ZON and driven by rules — the "prefer data over Lua" path,
  not a Lua-side table the engine cannot see, hot-reload, or hash.
- **A future native system can consume a data column** cache-coherently (it is a
  dense SoA column), the whole point of Option B over a per-entity map.
- **Committed to:** names declared in data before use; a scalar `f64` value type;
  the store entering the state hash in registration/dense order.
- **Explicitly not doing:** runtime-arbitrary keys (a new ADR if ever needed, behind
  this same seam); non-scalar value types (own ADR); removing a registered column mid-
  run (columns are append-only, so ids stay stable — a `remove`/unregister story, if
  ever needed, is its own decision).
