# 0015. Script↔engine host seam: how `mana` reaches the live Sim

- Status: proposed
- Date: 2026-07-12

## Context

ADR 0003 §2 fixes the `mana` API table's v1 surface. Three members that need no
live Sim are implemented (`version`, `log`, `is_valid`); the rest of the v1 surface
— `position`, `get`, `set`, `set_velocity`, `spawn`, `despawn`, `now`, `random`,
`random_int` (issue #5) — reads or mutates engine-owned state: component storage
(`World`), the deferred command buffer (`engine.command.CommandBuffer`, already
built), the sim clock, and the sim's seeded `core.Rng`. Snake (#31), the North-Star
package, cannot be written until this surface exists.

The blocker is a **module-boundary** one, not missing infrastructure. The `mana`
functions live in `src/script/mana.zig`, and the import DAG has **`script → core`
only** (CLAUDE.md; `src/script/CLAUDE.md`). `script` may not import `ecs` or
`engine`, so a `mana` C-function literally cannot name `World`, `CommandBuffer`, or
`ecs.Entity` to touch them. The seam must therefore be **inverted**: `script`
declares an abstract host interface in `core`-only terms, and `engine` — which
already depends on `script` and drives dispatch through `src/engine/script_runtime.zig`
— supplies the concrete implementation. Nothing Lua/engine-specific crosses back up;
the "nothing above `script` sees a Lua type" invariant is unaffected because the
interface is plain function pointers over `core` types.

ADR 0003 calls this "the most important interface in the project," so it gets its own
ADR rather than being improvised inside #5.

Forces in tension:
- **DAG direction.** `script` cannot depend on `engine`; the dependency must point
  the other way, so the interface lives in `script` and is *filled* by `engine`.
- **Existing closure pattern.** `mana.is_valid` already captures a `*const Registry`
  as a light-userdata upvalue. A host context fits the same mechanism — no new Lua
  machinery.
- **Determinism.** Every member must stay deterministic (CLAUDE.md; ADR 0003 §7):
  reads are pure, mutations must route through the existing deterministic command
  buffer, `now` is tick-derived, and RNG must draw from the sim's seeded stream, not
  a fresh one.
- **No stubs.** `src/script/CLAUDE.md` is emphatic: an absent `mana` key is the
  honest signal for "not wired." Whatever ships must be real, not faked.

## Decision

1. **`script` defines a `Host` value type** (in a new `core`-only file, e.g.
   `src/script/host.zig`): an opaque context pointer plus a vtable of function
   pointers. Every signature uses only `core`/builtin types — `u64` packed handles
   (the ADR 0003 §4 layout `handle.zig` already owns), `core.Vec3`, `[]const u8`
   component names, `f64`/`i64`/`bool`:

   ```
   pub const Host = struct {
       ctx: *anyopaque,
       vtable: *const VTable,

       pub const VTable = struct {
           position:      *const fn (ctx: *anyopaque, h: u64) ?core.Vec3,
           get:           *const fn (ctx: *anyopaque, h: u64, name: []const u8) ?f64,
           set:           *const fn (ctx: *anyopaque, h: u64, name: []const u8, v: f64) void,
           set_velocity:  *const fn (ctx: *anyopaque, h: u64, v: core.Vec3) void,
           spawn:         *const fn (ctx: *anyopaque, prototype: []const u8, pos: core.Vec3) u64,
           despawn:       *const fn (ctx: *anyopaque, h: u64) void,
           now:           *const fn (ctx: *anyopaque) f64,
           random:        *const fn (ctx: *anyopaque) f64,
           random_int:    *const fn (ctx: *anyopaque, lo: i64, hi: i64) i64,
       };
   };
   ```

   (`after`/`every`/`cancel` are deliberately **excluded** — they need the timer
   wheel, a separate task; #5 does not list them either.)

2. **`State` holds an optional `?Host`, set by `engine` around each dispatch.**
   `pushManaTable` captures a stable pointer to the `State`'s `Host` slot as the new
   closures' upvalue (same light-userdata trick as `Registry`). `engine` sets the
   slot to a live `Host` immediately before invoking a handler and clears it after,
   so a `mana` mutator called outside a dispatch (there is none in v1) is a safe
   no-op / nil rather than a dangling deref.

3. **`engine` implements the vtable over the Sim** (in `script_runtime.zig` or a
   sibling): `ctx` is the `Sim` (or a small per-tick struct holding `*World`,
   `*CommandBuffer`, the clock reading, and `*core.Rng`). Reads (`position`, `get`,
   `now`, `random`, `random_int`) resolve **immediately** against live state;
   mutations (`set`, `set_velocity`, `spawn`, `despawn`) **queue on the existing
   command buffer** and resolve at the tick's flush point (ADR 0003 §2 "resolves next
   tick"; ADR 0007 §3). `spawn` reserves a handle immediately via
   `CommandBuffer.spawn` (already implemented) and returns its packed `u64`.

4. **Handle validity is the host's job.** The host resolves a `u64` against the live
   world's generation table; a stale/forged handle makes an accessor return nil
   (reads) or drop silently (mutations), per ADR 0003 §4. This supersedes the
   `State`-local `entities: Registry` placeholder for the live surface: `is_valid`
   and the accessors consult the real world through the host once wired. (Whether the
   `Registry` is retired or kept as the host's own table is an implementation detail
   of #5, not fixed here.)

5. **Determinism is preserved by construction.** Reads are pure; mutations use the
   deterministic command buffer (including ADR 0003 §9 rollback on a throwing
   handler); `now` is tick-derived, not wall-clock; `random`/`random_int` draw from
   the sim's already-seeded `core.Rng` — the same stream the sim uses — so a given
   seed + input trace still yields a bit-identical state hash. The seam adds nothing
   to the state hash and does not change the determinism golden.

## Consequences

- **#5 becomes implementable** as one focused change: add `host.zig` + the nine
  `mana` accessors that call through it (script side), implement the vtable and set
  the slot around dispatch (engine side), and test reads/deferred-writes/now/random.
  **#31 (Snake) unblocks** once #5 lands.
- **The DAG stays intact.** `script` gains no new dependency (the interface is
  `core`-only); `engine → script` already exists. Nothing above `script` sees a Lua
  or handle-internal type.
- **One concrete host impl, one interface** — this satisfies the "second concrete
  impl planned, or don't abstract" rule differently: the abstraction is not
  speculative flexibility but the *only* way to honor the import DAG (a load-bearing
  dependency, per the abstraction policy). A test double (a fake `Host` over a plain
  `World`) also exercises the seam without a full `Sim`.
- **We are committed** to threading a live `Host` through dispatch every tick and to
  routing all script mutations through the command buffer — no direct `World`
  mutation from a `mana` call, ever.
- **Explicitly not doing:** timers (`after`/`every`/`cancel`) — deferred to the
  timer-wheel task; a comptime/generic seam instead of a runtime vtable (rejected:
  the `mana` C-functions register as plain closures and cannot be monomorphized over
  an engine type without `script` naming it); any new components Snake may need —
  those are discovered gaps filed against #31, not designed here; exposing raw
  pointers or engine types across the seam (forbidden by ADR 0003 §4 and invariant
  #4).
- **Follow-up ADR implied:** the timer wheel behind `after`/`every`/`cancel`, when a
  package needs scheduled callbacks.
