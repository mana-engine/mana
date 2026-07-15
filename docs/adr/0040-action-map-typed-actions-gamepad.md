# 0040. Data-driven action-map: typed (device-agnostic) actions + gamepad

- Status: accepted
- Date: 2026-07-15

## Context

Today a script sees input as raw physical keys and nothing else: `on_key(ev = { key,
pressed })` dispatches keyboard **edges** by diffing the deterministic `InputSnapshot`
stream (ADR 0021), native systems poll held keys internally (`ctx.input.keys.contains`,
`src/engine/input.zig`), and `InputSnapshot` also carries mouse/wheel that nothing
downstream reads (ADR 0009). There is **no `mana.*` input accessor** — Lua cannot read
held state — and **no gamepad** anywhere in the stack (`platform.Key` is 11 keyboard
keys). ADR 0021 §5 explicitly deferred held-state polling ("added when that concrete
need lands, not now"); ADR 0009 explicitly deferred gamepad ("no gamepad in v1").

Two concrete needs have now landed together (issue #190, a user request + a cross-engine
survey of Godot 4, Unity Input System, Unreal Enhanced Input, and Bevy + leafwing):

- **Remappable, device-agnostic control.** All four surveyed stacks converge on one
  architecture: a **named action** is decoupled from physical inputs; a **binding table**
  maps one-or-many physical inputs → each action; game code reads the *action*, never
  the key; remapping = editing the binding. Lean frameworks that skip this (LÖVE, Raylib,
  MonoGame) force every game to rebuild it. mana fits this better than any surveyed
  engine — the binding table is exactly the kind of thing our vision says belongs in
  **data** (invariant #1, files are the source of truth; invariant #6, genre lives in
  content), hot-reloadable and a node-graph target — and it is what makes gamepad support
  "fall out for free" behind one layer (invariant #5).
- **Held / continuous state in Lua** (ADR 0021 §5's deferred half): Tetris DAS (#63) and
  a platformer's run-while-held (#64) need level state that edge `on_key` alone cannot
  give; analog movement/aim needs a *value*, not a bit.

**⭐ Hard requirement — analog stays analog.** The user's binding guidance (2026-07-15)
is explicit: do **not** discretize a gamepad stick into digital key-equivalent actions.
That is acceptable for a 4-direction grid game but wrong for continuous facing, 8-way
turning, or a 3D body later — it throws away magnitude and true direction. Actions must
therefore be **value-typed**: a stick feeds an *analog* action and is never routed
through the digital edge path.

This is a scripting-surface change, so ADR 0003 §5 ("**any** change to the surface …
requires its own ADR") mandates this ADR; it also extends the `platform` port (ADR 0009).
This ADR *pins the design* — the event/poll surface, the binding-file format, the
`InputSnapshot` extension, and the determinism/versioning treatment — and blocks the
three implementation lanes (#192 held-poll, #193 gamepad physical layer, the data-driven
map itself). It implements none of them.

Forces settled elsewhere, applied here rather than re-litigated:

- **`on_key`'s edge shape is the good one** (ADR 0021): one event carrying a `pressed`
  flag, global, `self`-less, no key-repeat event. Separate `on_key_pressed`/
  `on_key_released` and a distinct repeat event are redundant — the `pressed` flag
  subsumes them; DAS/repeat stays content-built on edges + timers. `on_action` copies
  this shape rather than inventing a second one.
- **Event-driven where a reaction fires; poll only for genuinely continuous state**
  (ADR 0003 §1/§3, restated by ADR 0021's poll-vs-edge analysis). A discrete press is an
  edge; a stick magnitude read every tick is a poll. Both are legitimate; the split is
  the design, not an accident.
- **Input is deterministic-but-hash-excluded** (ADR 0009 §4, ADR 0021 §4): the
  `InputSnapshot` stream replays bit-identically yet never enters `World.stateHash`; the
  *effects* a handler applies are hashed as usual. Analog floats fold in the same way.
- **One small, additive, versioned surface** (ADR 0003 §5, CLAUDE.md): pin exactly what
  #191 asks; no speculative interaction state machines, no full keycode set.

## Decision

### 1. Actions are value-typed: `button` / `axis1d` / `axis2d`

An action declares a value **type**, and the type dictates how a script reads it:

| Type | Value | Script reads it via | Example |
|---|---|---|---|
| `button` | digital (down / up) | **`on_action` edge** + `mana.action_down` poll | jump, rotate, hard-drop, interact, pause |
| `axis1d` | one `f32` | `mana.action_axis` poll | throttle, a single trigger, 1-D strafe |
| `axis2d` | an `(x, y)` vector | `mana.action_vector` poll | move, aim, look |

**⭐ The invariant:** a physical **analog** source (a stick, a trigger) may bind **only**
to an `axis1d`/`axis2d` action and is surfaced as its float/vector value — it is
**never** thresholded into a `button` action inside the engine. (A game that *wants* a
digital "is the stick pushed right" reads the analog action and thresholds it in
content, where the policy belongs.) Digital sources may feed analog actions (§4), because
synthesizing a vector *up* from keys loses nothing; discretizing a vector *down* to a bit
does. The direction of the one-way street is the whole point.

### 2. The script surface: one event + three polls (plus a raw-key poll)

Added to ADR 0003's §3 event table and §2 `mana` table — additive, so **`mana.version`
stays `1`** (§7).

**Event (digital only), global and `self`-less, mirroring `on_key`:**

| Handler | Signature | Fired when |
|---|---|---|
| `on_action` | `(ev)` — `ev = { action, pressed }` | a **`button`** action's combined held-state transitions (`pressed = true` on the down edge, `false` on the up edge). `action` is the action name string (the ZON key, §3). Dispatched by diffing the deterministic snapshot exactly as `on_key` is (ADR 0021 §2), in a stable action order, host-live before timers. An `axis1d`/`axis2d` action **never** fires this event. |

**Polls (level / continuous state):**

- `mana.action_down(name) -> bool` — is a `button` action held this tick.
- `mana.action_axis(name) -> f32` — an `axis1d` action's value.
- `mana.action_vector(name) -> x, y` — an `axis2d` action's value as **two returns**
  (not a table), the `mana.position(h) -> x, y, z` convention (ADR 0003 §2). Multiple
  returns are deliberate: a poll read every tick that returned a fresh Lua table would
  heap-allocate every frame, which invariant #3 (no per-frame heap alloc in the hot loop)
  forbids; two numbers on the Lua stack allocate nothing.
- `mana.key_down(name) -> bool` — the ADR 0021 §5 deferred **raw-device** keyboard poll,
  keyed by the same `@tagName` strings `on_key` already uses (`"up"`, `"w"`, …). It reads
  the current `InputSnapshot.keys` directly — the same held-state native systems already
  poll — and **coexists** with `action_down`: `key_down` is device-specific ("is *this
  key* down"), `action_down` is device-agnostic ("is *this action* held, by whatever is
  bound"). Godot ships both (`is_key_pressed` / `is_action_pressed`) for the same reason:
  a raw-key escape hatch for content that genuinely wants a specific physical key (a debug
  toggle, a hard-coded tool key) without inventing an action for it.

**The lifecycle is exactly the minimal triad + the analog value, nothing more:**
*just-pressed* and *just-released* are the two `on_action` edges (`pressed` true/false);
*held* is `action_down`; the analog *value* is `action_axis`/`action_vector`. There is
**no** interaction state machine (Hold / Tap / MultiTap / Combo / charged press) — a game
builds those on edges + timers (ADR 0019), the same decision ADR 0021 made for DAS.
There are **no** `action_just_pressed`/`action_just_released` *poll* functions: the edge
*is* the event, so a poll would be a redundant second path to the same fact.

### 3. The binding table is DATA: `input.zon`

Bindings live in a per-game-package `input.zon` (located via the `game.zon` manifest,
laid out per ADR 0038), engine-interpreted, **hot-reloadable** (ADR 0005), and a
node-graph target. Nothing in `src/**` names an action; the action namespace is entirely
content (invariant #6). Remapping — a settings screen (#135), or a mod — is **editing this
file**, never a runtime DI call (invariant #1: files are the source of truth). Shape:

```zon
.{
    .actions = .{
        // digital: any listed source held ⇒ action held; edges are OR-combined (§4).
        .jump = .{ .type = .button, .keys = .{ .space }, .pad_buttons = .{ .south } },
        .pause = .{ .type = .button, .keys = .{ .escape }, .pad_buttons = .{ .start } },

        // analog 2-D: a stick (native analog) OR the WASD/arrow keys (synthesized, §4).
        .move = .{
            .type = .axis2d,
            .pad_stick = .left, // left | right — the whole stick, x+y at once
            .keys_2d = .{ .up = .{.up}, .down = .{.down}, .left = .{.left}, .right = .{.right} },
            .deadzone = 0.15, // radial; applied engine-side before the value reaches Lua
        },

        // analog 1-D: a trigger, or a +/- key pair synthesized to [-1, 1].
        .throttle = .{ .type = .axis1d, .pad_axis = .right_trigger, .keys_1d = .{ .pos = .{.w}, .neg = .{.s} } },
    },
}
```

A `button` action binds flat `keys`/`pad_buttons` lists. An analog action binds a native
analog source (`pad_stick`/`pad_axis`) and/or a **composite** key mapping (§4). Multiple
physical inputs per action is the norm, not a special case — that is what device-agnostic
means. Bindings are **many-to-one** (several inputs → one action); the same physical input
appearing in two actions is allowed (both fire), a content decision the engine does not
police.

### 4. Digital→analog synthesis, multi-source resolution, dead-zone — the resolver

The engine resolves `InputSnapshot` → per-action values each tick, as a **pure function
of the snapshot** (so determinism §6 holds):

- **Composite keys → an analog value.** An `axis2d` action's `keys_2d` maps four
  key-groups (`up`/`down`/`left`/`right`) to a vector: held opposites cancel, the raw
  vector is **normalized to unit length when its magnitude exceeds 1** (so a diagonal key
  combo is not `√2` faster than a straight one, and a stick's in-range magnitudes pass
  through untouched). `axis1d` `keys_1d` maps a `pos`/`neg` group to `{-1, 0, +1}`. This
  is what lets one `mana.action_vector("move")` read a keyboard and a stick **identically**
  — the device-agnosticism the whole ADR exists to deliver.
- **Multi-source resolution.** A `button` action's held-state is the logical **OR** of all
  its bound sources; its edge is the transition of that OR (so releasing the key while the
  pad button is still down does *not* fire an up-edge). An analog action's value is the
  bound source with the **greatest magnitude** this tick (a resting stick never overrides
  active keys and vice-versa), ties broken by binding order for determinism.
- **Dead-zone** is a per-action data field (`deadzone`, engine default when omitted),
  applied **radially** engine-side to native analog sources before the value reaches
  script — so content never re-implements stick dead-zones and every game is consistent.

### 5. Gamepad enters the `platform` port

`platform.InputSnapshot` (ADR 0009) gains a gamepad, as plain data alongside `keys`:

- `GamepadButton` — an engine-owned enum of SDL's standardized names (`south`/`east`/
  `west`/`north` face buttons, `dpad_up/down/left/right`, `left_shoulder`/`right_shoulder`,
  `left_stick`/`right_stick` clicks, `start`/`back`/`guide`). Held set: `pad_buttons:
  EnumSet(GamepadButton)`, mirroring `keys`.
- `GamepadAxis` — sticks `left_x`/`left_y`/`right_x`/`right_y` in **`[-1, 1]`**, triggers
  `left_trigger`/`right_trigger` in **`[0, 1]`**. Stored as a fixed `f32` array indexed by
  the enum. **First-class analog** — never pre-discretized (issue #193 ⭐).
- `pad_connected: bool` — whether a gamepad is present this tick.
- **One gamepad (player 1) in v1.** Local-multiplayer pad routing (N pads → N players) is
  deferred until a game needs it — a fixed enum-indexed second pad is a trivial additive
  extension when it does.

The **SDL3 adapter** samples this via `SDL_Gamepad` (**no new dependency** — SDL3 is
already the platform adapter, ADR 0013) and maps SDL scancodes/axes to the engine enums,
exactly as it already maps keys; nothing above `platform` sees an SDL type. The
**headless adapter** exposes injectable gamepad state (like its existing
`scripted_input`), so tests and recorded replays drive the pad deterministically with no
device.

**Connect / disconnect is a flag, not an event, in this ADR.** `pad_connected` is level
state a game polls (a "reconnect controller" pause screen reads it); it replays
deterministically like every other snapshot field. An `on_gamepad_connected` *edge* event
is **deferred** — add it (its own additive change) only when a game must react on the
transition rather than poll the level, the same restraint ADR 0021 applied to key-repeat.

### 6. Determinism & hash-exclusion

Actions are a **pure, deterministic function of the already-deterministic, already
hash-excluded `InputSnapshot` stream** (ADR 0009 §4 / ADR 0021 §4): key diffs, composite
synthesis, multi-source OR/max resolution, radial dead-zone, and gamepad
button/axis/connected sampling are all pure. The **analog `f32` axes fold in exactly like
keys** — the recorded snapshot trace carries them, replay is bit-identical, and they
**never enter `World.stateHash`**. `on_action` edges are derived by the same
snapshot-diff `on_key` uses, so the same trace yields the same edge sequence in the same
order. What *is* hashed is only whatever gameplay mutation a handler applies through the
ADR 0003 §2 command buffer — an action is a trigger, not a state fork. The pinned
state-hash golden does not move; the determinism CI test (same seed + inputs ⇒
bit-identical hash) covers analog input by construction.

### 7. Versioning, sandbox, error policy, budget — inherited from ADR 0003

- **Purely additive:** one new event key (`on_action`) and four new `mana` functions
  (`action_down`/`action_axis`/`action_vector`/`key_down`) — no changed signature, no
  changed handle layout. Per ADR 0003 §5 the surface is additive within a version, so
  **`mana.version` stays `1`** (as ADR 0039 also kept it). A package still declares
  `script_api = 1`.
- **Sandbox/error policy is ADR 0003 §7/§9 verbatim:** the new accessors join the `mana`
  allowlist and touch no filesystem/OS; `on_action` dispatch is `pcall`-wrapped, an error
  discards that invocation's command buffer and trips the same N = 8 circuit breaker,
  re-enabled by a script hot-reload.
- **Budget:** action resolution + `on_action` dispatch run inside the same per-frame
  Tracy zone and 0.5 ms script budget ADR 0003 §6 fixes; the pure resolver is native and
  cheap. No separate input budget.

### 8. Downstream / cross-cutting — noted, not designed here

- **#194 (heading ↔ MSF facings).** An `axis2d` `move`/`aim` produces a **continuous**
  heading, but MSF directional animation (ADR 0033) authors only 4 screen-space facings
  (up/down/left/right, mirror-by-absence). Resolving a continuous heading to a sprite
  facing — 8-way? N-way? a heading→clip curve? — is a **separate design** (#194), which
  this ADR only *enables* by making a continuous heading readable. It is explicitly out
  of scope; this ADR must not bake a 4-direction assumption a 3D body would break.
- **#146 (content-facing HEADING).** The heading a stick sets is exactly the "content
  HEADING decoupled from sim `Velocity`" #146 wants. This ADR pins how the heading is
  *read* (`action_vector`); how it is *stored/consumed* as a facing component is #146/#194.

### 9. Explicitly deferred (each with its one-line reason)

- **Mouse-to-script** — the port already carries mouse/wheel, but world-mouse has no game
  need yet and UI clicks are ADR 0039's job.
- **Text / IME input** — no game needs typed text; a distinct subsystem (candidate
  windows, composition) when one does.
- **Modifier keys / full keycode set** — the `Key` enum grows key-by-key on concrete need
  (ADR 0009's stated policy), not a speculative full keyboard.
- **Interaction state machines** (Hold/Tap/MultiTap/Combo/charge) — content builds these
  on edges + timers (§2), consistent with ADR 0021's DAS decision.
- **`on_gamepad_connected` edge event** and **multi-gamepad / local co-op routing** (§5).
- **Separate `on_key_pressed`/`on_key_released` and a key-repeat event** — subsumed by
  `on_key`'s `pressed` flag (rejected outright, see Alternatives).

## Alternatives considered

- **Discretize sticks into digital actions** (a stick pushed past a threshold fires a
  button-action). **Rejected — the user's hard requirement.** It is fine for a 4-cell grid
  but destroys magnitude and true direction for continuous facing / 8-way / a future 3D
  body; the analog value can never be recovered downstream. Analog sources are one-way
  *into* analog actions only (§1).
- **Analog action returns a Lua table `{x, y}`** (issue #191's illustrative shape). Chosen
  the two-return form instead: a per-tick poll returning a fresh table heap-allocates every
  frame (invariant #3), and multiple returns match the established `mana.position` shape.
- **A flat `keys = .{…}` list for an `axis2d` action** (issue #191's illustrative binding
  shape). Rejected: a flat key list is ambiguous for a 2-D action — it says *which* keys bind
  but not which direction each drives, so the engine cannot synthesize a vector from it. The
  per-direction `keys_2d = .{ .up, .down, .left, .right }` composite (§4) names each direction
  explicitly, which is what lets held opposites cancel, diagonals normalize to unit length, and
  a keyboard read through `action_vector` identically to a stick. `axis1d` takes the same shape
  as a `pos`/`neg` pair (`keys_1d`). The flat list is kept only for `button` actions, where
  there is no direction to disambiguate.
- **Redundant `on_key_pressed` / `on_key_released` + a key-repeat event.** Rejected: the
  single `on_key(pressed)` edge already carries both transitions, and repeat/DAS is content
  on edges + timers — this is ADR 0021's decision, restated, not reopened.
- **Runtime remapping API** (`mana.bind(action, key)` mutating bindings in Lua). Rejected:
  it makes the running process, not the file, the source of truth (violates invariant #1);
  a settings screen edits `input.zon` and the hot-reload path (ADR 0005) re-applies it.
- **An interaction state machine in the engine** (Enhanced-Input-style Hold/Tap/Combo
  triggers as data). Rejected as speculative for now: no game needs it, and edges + timers
  cover the concrete cases; revisit via its own ADR when a game genuinely does (CLAUDE.md
  "second concrete impl planned, or don't abstract").
- **Drop `key_down`, expose only actions.** Rejected: a debug/tool key or a one-off
  physical binding shouldn't require inventing an action; Godot keeps both device-specific
  and action polls for exactly this, and it is the literal deferred half of ADR 0021 §5
  (#192). The two coexist, clearly labelled device-specific vs device-agnostic.
- **A connect/disconnect *event* instead of a flag** (§5). Rejected for v1: a flag is the
  minimal primitive, replays deterministically, and content derives the edge if it must;
  the event is a clean additive follow-on when a concrete reaction needs it.

## Consequences

- **Easier:** every game gets remappable, device-agnostic controls for free — bind in
  `input.zon`, read the *action*, and a keyboard, a stick, or both drive it identically;
  gamepad support genuinely "falls out" behind the map (invariant #5). Held/continuous
  state reaches Lua at last (#63 DAS, #64 run-while-held). The three impl lanes (#192,
  #193, the data map) now have an unambiguous, ADR-backed target and can proceed.
- **Harder / accepted:** the engine grows a pure per-tick **action resolver** (composite
  synthesis, OR/max multi-source, radial dead-zone) and must keep it deterministic and
  hash-excluded; `platform.InputSnapshot` and both adapters grow a gamepad; a new
  content file format (`input.zon`) needs a parser, a hot-reload hook, and validation
  (unknown action name, wrong-typed poll, unbound source).
- **Committed to (once accepted):** the three action types and the one-way analog rule
  (§1); the `on_action` event + the four polls with their exact shapes, incl.
  two-return `action_vector` (§2); `input.zon` as the data binding table (§3); the
  resolver's synthesis/resolution/dead-zone semantics (§4); the `InputSnapshot` gamepad
  extension with SDL-standardized enums, single pad, connected-flag (§5); the
  determinism/hash-exclusion treatment (§6); `mana.version` unchanged at `1` and ADR 0003
  §7/§9 sandbox/error policy verbatim (§7).
- **Explicitly not doing here:** everything in §9, and the entire #194 heading↔facing /
  #146 heading-component design (§8) — this ADR enables it, it does not design it.

Cross-references: #190 (epic), #191 (this ADR), #192 (`key_down` / held-poll lane), #193
(gamepad physical layer), #194 + #146 (continuous heading ↔ MSF facing, downstream);
builds on ADR 0003 (scripting surface — event table, `mana` table, handle/version/sandbox
policy), ADR 0009 (platform port + `InputSnapshot` + input determinism/hash-exclusion),
ADR 0021 (`on_key` — the edge shape `on_action` copies and the §5 deferral this resolves),
ADR 0005 (hot-reload, for `input.zon`), ADR 0013 (SDL3 adapter — hosts `SDL_Gamepad`, no
new dep), ADR 0038 (game package layout — where `input.zon` lives), ADR 0033 (MSF
directional animation — the facing dimension #194 must reconcile with).
