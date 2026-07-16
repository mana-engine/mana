# 0041. In-game action-map remapping: capture-next-input, a persisted user override, live swap

- Status: proposed
- Date: 2026-07-16

## Context

ADR 0040 (accepted) made the binding table **data**: a per-package `input.zon`
declares typed actions (`button`/`axis1d`/`axis2d`) and the physical inputs bound to
each; the engine resolves `InputSnapshot → per-action values` each tick and a script
reads the *action*, never the key. Its §3 pins remapping as **"editing this file"**,
and its Alternatives reject a runtime `mana.bind(action, key)` mutator: "it makes the
running process, not the file, the source of truth (violates invariant #1); a settings
screen edits `input.zon` and the hot-reload path (ADR 0005) re-applies it."

Issue #201 is that settings screen — but from a player's chair, not a text editor. It
asks for **three player-facing capabilities that do not exist today**, plus the two
plumbing gaps that make them work:

1. A **controls screen** that lists actions and lets the player rebind each by
   *pressing the input they want* ("press a key to bind"). ADR 0034/0039 gave us
   screens, focus nav, and `on_click`/`on_focus`/`on_activate` — but **no way to
   capture an arbitrary next physical input** and report *which* key/button it was.
   `src/engine/ui_dispatch.zig`'s `UiInput.keyEdge` (`:95`) recognises only the fixed
   nav/activate set (`ui.navDirection`/`ui.isActivateKey`, `src/ui/focus.zig:25,39`);
   every other key returns `false` and falls straight through to gameplay `on_key`
   (`:115`). No mode intercepts "the next input, whatever it is."
2. **Persisted-across-runs bindings.** The rebound map must survive a restart. Writing
   the shipped package `input.zon` from the running game is wrong (it dirties the
   package and mixes per-user prefs into shared content); nothing currently loads a
   file *over* the package map.
3. **Live re-bind.** Applying a binding must take effect immediately — the action map
   must hot-reload. Today `input.zon` is **absent from the watch set**
   (`syncWatchSet`, `src/runtime/main.zig:938`, watches `game.zon`/hud/`scenes`/
   `prototypes`/`scripts` only); `onChange` (`:1201`) re-parses the manifest and
   rebuilds the *world from the scene*, never the action map; `runWatch` (`:1169`)
   builds a bare `world` and runs `engine.systems.movement`, not a `Sim` — so there is
   no `Sim.action_map` to swap in `--watch` at all; and the windowed `runPlay`
   (`:632`) has **no watch/reload of any kind**.

The load half of ADR 0040 §3 *has* landed (#216): `loadActionMap` (`:236`) parses the
manifest's `.input` path (`src/runtime/manifest.zig:61`, `input: ?[]const u8`) and
every run mode borrows it onto `Sim.action_map` (`:373,495,591,684,919`), a borrowed
`?*const ActionMap` (`src/engine/sim.zig:111`) mirroring the tilemap. So the *read*
path is real; the *write*, *overlay*, and *reload* paths are all still missing.

Persistence has a precedent but not a shipped one. Issue #135's settings pattern is:
Lua holds values as plain handler-table fields (`t.volume`), an engine-side driver
reads them via `Runtime.handlerFieldInt` (`src/engine/script_runtime.zig:616`) and
writes a ZON file with `data.zon.saveFile` (`src/data/zon.zig:135`; `loadFile` at
`:123`). **Caveat that shapes this ADR:** that driver exists only in
`tests/menu_acceptance.zig` (`:140-155`, saving to a *temp* dir) — it is **never wired
into `runPlay`/`runWatch`**. So "settings actually persist during `--play`" is itself
unshipped; only the `saveFile`/`loadFile`/`handlerFieldInt` primitives exist in
shipped code. Writing bindings from Lua directly is in any case impossible: ADR 0003
§7's `_ENV` allowlist removed `io`/`os`/`package` — a script cannot touch the
filesystem. **Persistence must be engine-side Zig**, driven off values the script
exposes as handler-table fields, exactly the #135 shape generalised.

Two ADR-0039 gaps a full remap *flow* leans on are noted but not this ADR's to fix:
screen-switching from `on_activate` (ADR 0039 §6 scopes multi-screen out — "one active
screen today") and a visible focus indicator. The controls-screen content (child issue
5) inherits whatever #135/#209 ship for those; this ADR designs the *engine primitives*
a remap UI needs, not the UI.

Forces settled elsewhere, applied here rather than re-litigated:

- **Files are the source of truth (invariant #1).** The player's rebindings must end
  up in a **file**, and the running map must be **derived from files** — not held only
  in process memory. This is why ADR 0040 rejected `mana.bind`. This ADR keeps that
  spirit: it adds a *second* file (a user override) that layers over the package
  `input.zon`; both are files, the engine still runs headless from files alone.
- **The scripting surface is small, additive, and ADR-gated** (ADR 0003 §5, CLAUDE.md).
  Capture-next-input is a new script capability, so it needs this ADR — and it stays
  additive, so **`mana.version` stays `1`** (as ADR 0039 and ADR 0040 also kept it).
- **Input is deterministic-but-hash-excluded** (ADR 0009 §4, ADR 0021 §4, ADR 0040 §6).
  Capture reads the same `InputSnapshot` stream every other input path reads; the
  capture *mode*, the override *file*, and the *reload* are all cosmetic/edge concerns
  that never enter `World.stateHash`, exactly like UI (ADR 0039 §4) and file-watch
  (ADR 0005 §4) already are.
- **Full-reload, last-good-wins, at a tick boundary** (ADR 0005 §2/§3). The live swap
  reuses that model wholesale — re-parse the effective map, swap the borrow between
  ticks, keep the last good map on a parse error.
- **Genre lives in content (invariant #6).** No action name, no key name, no
  menu concept enters `src/`. The capture/override/reload machinery is
  **engine-generic** — "capture the next input," "layer a user file over a package
  file," "reload the action map" — none of it knows an action called `jump` exists.

This ADR **pins the design and blocks the implementation lanes** (§Decomposition); it
implements none of them. It also **amends ADR 0040 §3** (see §2).

## Decision

### 1. Capture-next-input: an engine capture mode, armed from script, delivered as an event

The engine gains a **capture mode** owned by the UI-input layer (`UiInput`,
`src/engine/ui_dispatch.zig`) — the same layer that already sits *ahead of* gameplay
`on_key` and decides what gameplay is allowed to see (ADR 0039 §3). Capture is one
more "UI claims this edge first" rule, not a new input subsystem.

**Arming (script → engine), one new `mana` call:**

- `mana.capture_input(action) -> nil` — arm capture for the named action. While armed,
  the **next** physical input *edge* (see below) is intercepted by the engine, reported
  to content, and consumed (it does **not** reach gameplay `on_action`/`on_key`, nor
  drive focus nav). `action` is the action-name string (the `input.zon` key, an opaque
  content string to the engine — invariant #6). Arming is idempotent; re-arming
  before an edge arrives replaces the pending target.
- `mana.cancel_capture() -> nil` — disarm without binding (the player pressed
  *Escape*/*Back*, or navigated away). Completes the minimal arm/deliver/cancel triad.

**Delivering (engine → script), one new event, mirroring `on_action`'s shape:**

| Handler | Signature | Fired when |
|---|---|---|
| `on_input_captured` | `(ev)` — `ev = { action, source }` | while capture is armed for `action`, the first qualifying physical **press edge** is seen. `source` is a **neutral binding descriptor string** (§1.1) naming the physical input — the same device-neutral string vocabulary `input.zon` already uses (`"space"`, `"pad_south"`, …). `self`-less and global, exactly like `on_action`/`on_key`. |

The event *reports*; it does not *bind*. Content receives `{action, source}`, decides
whether to accept it (reject a reserved key, reject a duplicate, echo it in the UI),
and — to actually persist and apply it — writes the new binding as a **handler-table
field** the engine-side driver reads (§4), the #135 pattern. There is **no**
`mana.bind` mutator (ADR 0040's rejected alternative stands): script proposes a value
as data; the engine owns the file write and the reload.

**Why an event, not a poll.** A capture is a discrete "the player just pressed the key
they want" transition — an edge, precisely the poll-vs-edge split ADR 0021/0040 §2 draw
(a reaction fires ⇒ event; continuous level state ⇒ poll). A poll (`mana.captured()`
returning a value or nil each tick) would be a second path to the same one-shot fact
and would risk a missed/duplicated read across ticks; the edge is delivered exactly
once, host-live, like every other input edge.

**Where it intercepts.** In `UiInput`, *ahead of* both focus-nav routing and the
gameplay fall-through — a third branch before the existing `navDirection`/`isActivateKey`
checks in `keyEdge` (`:104-115`), and symmetrically for a new pad-button edge path.
When capture is armed, the branch consumes the edge and dispatches `on_input_captured`
instead of returning `false`; when disarmed, `keyEdge` behaves exactly as today. The
UI-first, consume-or-fall-through contract (ADR 0039 §3) is unchanged — capture is one
more thing the UI can claim before gameplay sees it.

**Why ADR 0039 does not already cover this.** ADR 0039 §6 explicitly scoped capture
out: it fires events for the *fixed* nav/activate keys and for widget hits; it has no
notion of "intercept an arbitrary next input and report which one." Capturing *any*
key/button — including ones ADR 0039 deliberately passes through to gameplay — is a
new capability that needs its own surface entry, which is why it lands here.

#### 1.1. What qualifies for capture, and analog is v1-deferred

- **Keyboard press edges** and **gamepad button press edges** are captured in v1 — the
  two digital edge streams the engine already diffs (`InputSnapshot.keys` and, per ADR
  0040 §5, `InputSnapshot.pad_buttons`). Release edges never trigger capture (you bind
  on press, mirroring `isActivateKey`'s press-only rule, ADR 0039 §1).
- **Analog-source capture (a stick, a trigger) is deferred.** Binding an `axis2d`/
  `axis1d` action to a *stick* by wiggling it needs an activation threshold + an
  axis-settle heuristic (which axis did the player mean, past what magnitude, for how
  long) that is real design and not needed to ship digital remapping. v1 captures
  **digital sources** and reports them; an analog action can still have its digital
  composite (`keys_2d`/`keys_1d`/`pad_dpad`) rebound key-by-key. Analog-source capture
  is a clean additive follow-on (its own event stays the same; only the qualifying set
  grows) — the same restraint ADR 0040 §5 used deferring `on_gamepad_connected`.
- **The captured `source` is a binding descriptor, not a raw scancode.** It is a
  neutral string in the exact vocabulary `input.zon` binding lists already use, so the
  driver (§4) can drop it straight into the override file with no translation:
  `"space"`/`"w"` for keys (the `@tagName` strings `on_key` uses), `"pad_south"`/
  `"pad_start"`/`"pad_dpad_up"` for pad buttons. The precise namespacing (a flat
  string vs. a `{kind, name}` pair) is an implementation detail the capture-lane issue
  settles against the parser it feeds; this ADR fixes that it is device-neutral and
  round-trips into `input.zon` syntax.

**Determinism.** Capture reads the same deterministic, hash-excluded `InputSnapshot`
stream every other edge reads (ADR 0009/0021/0040 §6); the capture *mode flag* and the
`on_input_captured` *dispatch* are UI-layer state, hash-excluded exactly like `on_key`/
`on_click` (ADR 0039 §4). Nothing new enters `World.stateHash`. A recorded input trace
replays the same capture edge at the same tick.

### 2. A user-override `input.zon` that layers over the package map (amends ADR 0040 §3)

The player's rebindings live in a **separate, engine-managed override file**, not in
the package `input.zon`. The effective action map the engine resolves against is the
**package map with the override's per-action bindings applied on top**.

- **Merge granularity: per-action replace.** The override is a partial `input.zon` —
  the same schema (ADR 0040 §3), but listing only the actions the player changed. For
  a listed action, the override's binding **wholly replaces** the package binding for
  that action (all of `keys`/`pad_buttons`/`pad_stick`/`keys_2d`/… for that action come
  from the override). An action *absent* from the override inherits the package default
  unchanged. Per-action replace — not per-source union — because "rebind jump to F"
  means *jump is now F*, not *jump is Space-or-F*; a union would make it impossible to
  ever remove a default binding, which is a thing a remap screen must be able to do.
  An action's `type` is **not** overridable (it is a content contract the script reads
  through; the override supplies bindings for an existing typed action, and an override
  naming an unknown action or supplying a source that violates the one-way analog rule
  is a load error, last-good-wins per §3).
- **Precedence: user override wins**, always, over the package default — that is the
  whole point of a per-user preference.
- **This amends ADR 0040 §3.** ADR 0040 §3 says remapping is "editing this file"
  (singular). This ADR admits a **second, equal, engine-managed source**: the effective
  map is `package input.zon` ⊕ `user override input.zon`, override-wins, per-action.
  Files are *still* the source of truth (invariant #1 intact) — there are simply **two
  layered files** now, both human-editable ZON, both watched, both re-applied by the
  reload path. The ADR-0040 rejection of a *runtime `mana.bind` mutator* is **not**
  reopened: the running process still never becomes the source of truth; the override
  is a file the engine writes and then re-reads, exactly the "edit the file + hot
  reload re-applies it" loop ADR 0040 endorsed, just with the "editing" done by an
  engine driver on the player's behalf instead of by a text editor.

#### 2.1. Override location — two options, one recommendation (reviewer's final call)

**Option A — a user-scoped OS config path** (e.g. XDG
`~/.config/mana/<pkg>/input.zon`, `%APPDATA%\mana\<pkg>\input.zon` on Windows).

- **Pro:** the shipped package stays pristine — no player artifact ever lands in
  `games/<pkg>/`; genuinely per-user (two users, two machines/profiles, two maps);
  it is where a released game's key bindings *belong*. Read-only/packaged game installs
  work (you cannot assume the package dir is writable in the field).
- **Con:** needs cross-platform config-root resolution (XDG on Linux, `%APPDATA%` on
  Windows) — new path code the engine does not have today; and a per-package
  sub-namespace keyed off the manifest identity so two games' overrides do not collide.

**Option B — a package-local `games/<pkg>/save/input.zon`**, mirroring #135's
`save/settings.zon` (`tests/menu_acceptance.zig:38`) verbatim.

- **Pro:** reuses the exact `save/` layout #135 already established; **zero new path
  code** — it is a package-relative join like every other content path
  (`std.fs.path.join(pkg, "save/input.zon")`), watchable by the existing `watchFile`
  helper (`:948`) with no changes; the whole feature ships without a config-dir
  resolver.
- **Con:** the override **dirties the package directory** — a player's personal
  bindings get written into what is supposed to be pristine, diffable, git-tracked
  content, and it assumes the package dir is writable.

**Recommendation: Option A (user config dir) is the correct end-state** — per-user
preferences belong in a per-user location, not smeared into shared content, and a
shipped game's install may be read-only. **But this ADR proposes Option B (`save/`) as
an explicit, argued v1 shortcut**, decoupling the remap feature from a cross-platform
config-root resolver: ship the capture/overlay/reload/persistence machinery against the
zero-ceremony `save/input.zon` path first (it is real, watchable, and reuses #135's
proven layout), then move *only the override location* to the config dir in a small,
isolated follow-up (the merge/precedence/reload/driver code is identical — only the
path-resolution call changes). This sequences the risky cross-platform path work out of
the critical path without committing the project to `save/` as the end-state. **The
final pick between "A now" and "B now, A next" is the reviewer's** — both are designed
here; the difference is one path-resolution function and when it lands.

### 3. Live action-map swap on change (ADR 0005 model)

Applying a binding — or any external edit to either the package `input.zon` or the
override — takes effect at the **next tick boundary**, via ADR 0005's full-reload,
last-good-wins model, generalised from the scene to the action map:

- **Watch both files.** `syncWatchSet` (`:938`) adds the package `input.zon` (when
  `manifest.input != null`) and the override path (§2.1) to the watch set, alongside
  the existing `game.zon`/hud/scenes/prototypes/scripts entries — reusing `watchFile`
  (`:948`) with no new mechanism.
- **Re-resolve the effective map, swap the borrow.** On a detected change to either
  file, `onChange` (`:1201`) re-parses the package map and the override, re-merges them
  (§2), and **swaps `Sim.action_map`** (`src/engine/sim.zig:111`) to point at the new
  owned `ActionMap` at the tick boundary — the same "borrowed like tilemap, outlives
  sim" ownership the load path already uses (`:373`, etc.), freeing the previous map
  after the swap. Because the action map is a *pure lookup table* the resolver reads
  each tick (ADR 0040 §4), swapping the pointer between ticks is atomic from the sim's
  view — no entity/world rebuild, unlike a scene reload.
- **Last-good-wins.** A malformed override or package `input.zon` (a syntax error, an
  unknown action, an analog-rule violation) keeps the **current** effective map, logs,
  and retries on the next change (ADR 0005 §3) — the running game never loses input to
  a bad edit, and the remap screen can surface the rejection.
- **The plumbing work this exposes.** `input.zon` is not in the watch set today, and
  the reload path handles only manifest+scene, not the action map — both must grow
  (child issue 3). More sharply: **`runWatch` builds no `Sim`** (`:1169`, it runs
  `engine.systems.movement` on a bare `world`) and **`runPlay` has no watcher at all**
  (`:632`). A live in-game remap happens in a *windowed* session, so `runPlay` is the
  mode that must gain a watch+reload path it wholly lacks. This ADR flags that as the
  substantive engine work of child issue 3; it does not prescribe the exact loop
  structure (that is the lane's, against the tick model `runPlay` already runs).

### 4. Persistence driver: engine-side Zig, the #135 pattern generalised

Persistence is **engine-side**, because Lua cannot write files (ADR 0003 §7) and must
not (invariant #1: the engine owns the file, the script proposes data). The driver
generalises #135's settings driver:

1. On a rebind the content accepts (in `on_input_captured`, §1), the script records the
   new binding into **handler-table fields** — the plain-Lua-state channel #135 uses
   (`t.volume`), read engine-side via `Runtime.handlerFieldInt`/its sibling accessors
   (`src/engine/script_runtime.zig:616`). A binding is richer than an int (an action
   name → a source string), so the driver reads whatever accessor shape the script
   exposes for "the pending/current bindings"; the accessor family may need a
   string-valued or table-valued sibling to `handlerFieldInt` — an **additive**
   `script_runtime` accessor, not a `mana`-surface change, so `mana.version` is
   untouched (the same "engine reads handler-table state" seam #135 already uses).
2. The driver serialises the changed bindings into the override `input.zon` (§2) via
   `data.zon.saveFile` (`src/data/zon.zig:135`) — the existing primitive, no new I/O —
   writing the same partial-`input.zon` shape the loader reads back (round-trippable
   ZON, the serializer's property-test contract).
3. The watch/reload path (§3) then re-reads the just-written override and swaps the
   live map — so a rebind **persists and applies in one motion**, and the same file is
   what loads on next run.

**Explicitly flagged prerequisite.** The #135 settings driver is **not wired into any
real run mode** — it exists only in `tests/menu_acceptance.zig` (saving to a temp
dir), never in `runPlay`/`runWatch`. So "engine-side persistence during `--play`" is
itself unshipped, for settings *and* for bindings. This ADR's position: **wiring an
engine-side persistence driver into `runPlay` is in-scope for child issue 4** (it is
the load-bearing half of "persisted across runs" and cannot be assumed to already
exist). Whether that lane *also* retrofits #135's *settings* persistence into
`runPlay` while it is there (the two share the read-handler-fields → `saveFile` seam)
is a bundling call for the orchestrator — noted in §Decomposition as an optional
add-on to issue 4, not a hidden dependency.

### 5. Determinism & scope hygiene

- **Wholly cosmetic / hash-excluded.** Every moving part here is already outside
  `World.stateHash`: UI + input capture (ADR 0039 §4, ADR 0021 §4), the override file
  and the map swap (file-watch is an edge concern, ADR 0005 §4), and the resolved
  action values themselves (ADR 0040 §6). The pinned state-hash golden does not move;
  the determinism CI test is unaffected (deterministic headless runs load fixed content
  and do not watch, ADR 0005 §4). A rebind changes *which physical input triggers an
  action*, never the sim state a triggered action mutates.
- **No genre/action/key name in `src/` (invariant #6).** The capture surface takes an
  opaque `action` string and yields an opaque `source` string; the override file is
  parsed by the same ADR-0040 action-map parser that already knows no action names;
  the driver serialises whatever bindings the content proposed. `src/` learns
  "capture the next input," "layer a user file over a package file," "reload the map" —
  three engine-generic capabilities — and never that a game has an action called
  `jump` or a key called `space` beyond the neutral string passing through.
- **Engine-generic, not menu-specific.** Nothing above is a "remap menu" feature: any
  screen (a pause menu, a first-run setup, a mod's config UI) can arm capture and
  propose bindings; the override/reload/persistence works for a package with no menu at
  all (hand-edit the override file, it hot-reloads). The menu is *content* (child issue
  5) that composes these primitives.

### 6. Versioning, sandbox, error policy — inherited from ADR 0003

- **Purely additive script surface:** one new event (`on_input_captured`) and two new
  `mana` functions (`capture_input`, `cancel_capture`) — no changed signature, no
  changed handle layout. Per ADR 0003 §5 the surface is additive within a version, so
  **`mana.version` stays `1`**; a package still declares `script_api = 1`.
- **Sandbox/error policy is ADR 0003 §7/§9 verbatim:** `capture_input`/`cancel_capture`
  join the `mana` allowlist and touch no filesystem/OS (the *engine* writes the
  override, not the script); `on_input_captured` dispatch is `pcall`-wrapped, an error
  discards that invocation's command buffer and trips the same N = 8 circuit breaker,
  re-enabled by a script hot-reload. The persistence driver and reload are engine-side
  and outside the Lua sandbox entirely.
- **Budget:** capture arming/dispatch runs inside the same per-frame script Tracy zone
  and 0.5 ms budget ADR 0003 §6 fixes; a capture edge is at most one dispatch per
  frame. No separate input budget.

### 7. Explicitly deferred (each with its one-line reason)

- **Analog-source capture** (bind a stick/trigger by moving it) — needs a threshold +
  axis-settle heuristic no digital rebind requires; additive follow-on (§1.1).
- **A runtime `mana.bind` mutator** — rejected by ADR 0040 and not reopened; the
  file+reload loop is the sanctioned path (§2).
- **The controls-screen UI's own missing pieces** — multi-screen switching from
  `on_activate` and a visual focus indicator (ADR 0039 §6) are #135/#209's to ship;
  child issue 5 consumes whatever they land.
- **Moving the override to the OS config dir**, if the reviewer takes the `save/` v1
  shortcut (§2.1) — an isolated path-resolution follow-up, everything else identical.
- **Per-device / per-profile override sets** (a keyboard map vs. a pad map, multiple
  named profiles) — one override per package in v1; a profile dimension is additive
  when a game needs it.

## Alternatives considered

- **A runtime `mana.bind(action, source)` mutator that rebinds in memory.** Rejected —
  ADR 0040 already rejected exactly this: it makes the running process the source of
  truth (violates invariant #1). This ADR keeps the file+reload loop; the only new
  thing is that an engine driver, not a text editor, writes the file.
- **Capture delivered as a poll (`mana.captured() -> action, source | nil`) instead of
  an event.** Rejected: a capture is a one-shot press *edge*, the exact case ADR
  0021/0040 §2 assign to events; a per-tick poll is a redundant second path to the same
  fact and risks a missed or double read across ticks. The event fires exactly once,
  host-live.
- **Write bindings from Lua directly** (expose a file-write to the sandbox). Rejected
  outright: ADR 0003 §7 removed `io`/`os` to close the mod filesystem threat surface
  and protect determinism; reopening it for one feature is a security regression. The
  engine owns the write.
- **Overwrite the package `input.zon` in place** (no override file). Rejected: it
  dirties shipped, git-tracked, diffable content with per-user state, breaks a
  read-only install, and cannot represent "two users, two maps." An override that
  layers over the package default keeps the package pristine.
- **Per-source union merge** (override *adds* bindings to the package defaults).
  Rejected: it makes removing a default binding impossible ("jump" would be forever
  "Space-or-whatever-you-added"), which a remap screen must be able to do. Per-action
  replace lets the player fully redefine an action's inputs.
- **Diff/patch the live action map instead of a full re-parse + swap.** Rejected as
  speculative: ADR 0005 §2 already chose full-reload over stable-identity diff/patch
  for scenes, and the action map is a small pure lookup table — swapping a borrowed
  pointer at a tick boundary is trivially correct and cheap; a differ buys nothing.
- **A dedicated capture input *port*/subsystem** separate from `UiInput`. Rejected as
  over-abstraction (CLAUDE.md "abstract only where the dependency is load-bearing"):
  capture is one more "UI claims this edge before gameplay" rule, and `UiInput` is
  already exactly the layer that owns that decision (ADR 0039 §3). A new port would
  duplicate its consume-or-fall-through contract.

## Consequences

- **Easier:** a game gets player-facing, persisted remapping by composing engine-
  generic primitives — arm capture, accept the reported input, let the engine persist
  and hot-swap — with no genre knowledge in `src/` and no new scripting *version*. Any
  screen (pause, first-run, a mod config) can drive it; a package with no menu can
  still hand-edit a hot-reloading override. #201's "press a key to bind, persisted
  across runs, live" is fully expressible.
- **Harder / accepted:** the engine grows a capture mode in `UiInput` (a third
  edge-claiming branch, plus a pad-button edge path), a two-file per-action merge with
  override-wins precedence, an `input.zon`-aware watch+reload that `runPlay` wholly
  lacks today, and an engine-side persistence driver that must actually be wired into
  `runPlay` (the #135 driver is test-only). The override-location cross-platform path
  work is real but sequenced out of the critical path (§2.1).
- **Committed to (once accepted):** the capture surface — `on_input_captured` +
  `capture_input`/`cancel_capture`, event-not-poll, digital-only v1, device-neutral
  `source` string (§1); the second-file per-action-replace override with override-wins
  precedence, **amending ADR 0040 §3** to two layered files (§2); the full-reload
  tick-boundary map swap with last-good-wins (§3); the engine-side driver reading
  handler-table bindings and writing the override via `data.zon.saveFile`, wired into
  `runPlay` (§4); the hash-exclusion/genre-hygiene treatment (§5); `mana.version`
  unchanged at 1 and ADR 0003 §7/§9 verbatim (§6).
- **Explicitly not doing here:** everything in §7, plus the controls-screen content and
  the ADR-0039 multi-screen/focus-indicator gaps it depends on.

## Decomposition into child issues

`#201` splits into five dependency-ordered, mostly file-disjoint lanes. Marked
**engine** (`src/`) or **content** (`games/`). The shared hot files are
`src/runtime/main.zig` (watch/reload/run modes), `src/engine/sim.zig`
(`action_map` borrow), `src/script/mana.zig` + `src/engine/ui_dispatch.zig` (capture
surface), and `src/engine/script_runtime.zig` (handler-field accessors) — lanes that
touch the same one should be sequenced, not run concurrently.

1. **Capture-next-input engine surface + script arm/deliver** — *engine*. Add
   `mana.capture_input`/`mana.cancel_capture` (`src/script/mana.zig`) and the
   `on_input_captured` dispatch (`src/engine/script_runtime.zig`); add the capture
   branch ahead of nav/gameplay routing in `UiInput.keyEdge` + a pad-button edge path
   (`src/engine/ui_dispatch.zig`); digital sources only, device-neutral `source`
   string. Touches `mana.zig`/`ui_dispatch.zig`/`script_runtime.zig`. Independent of
   2–4; foundational for 5.
2. **User-override load + per-action merge + precedence** — *engine*. Parse a partial
   `input.zon` override and merge it over the package map, per-action replace,
   override-wins, producing the effective `ActionMap` (`src/engine/action_map.zig` +
   the loader in `src/runtime/main.zig`). Validation/last-good on a bad override.
   Depends on nothing; feeds 3 and 4.
3. **`input.zon` live hot-reload + `Sim.action_map` swap + `runPlay` watch** — *engine*.
   Add package `input.zon` + the override to `syncWatchSet`; re-resolve + swap
   `Sim.action_map` at a tick boundary in `onChange`, last-good-wins; **give `runPlay`
   the watch+reload path it lacks** (and, if cheap, `runWatch` a `Sim`). Touches
   `src/runtime/main.zig` + `src/engine/sim.zig`. Depends on 2 (needs the merge to
   re-resolve). Highest merge-contention lane — owns `main.zig`.
4. **Engine-side persistence driver → override file** — *engine*. Read the accepted
   bindings off the handler table (a string/table-valued sibling to
   `handlerFieldInt`, `src/engine/script_runtime.zig`) and write the override via
   `data.zon.saveFile`; **wire the driver into `runPlay`** (the #135 driver is
   test-only). *Optional add-on:* retrofit #135's settings persistence into `runPlay`
   on the same seam. Depends on 1 (bindings arrive via capture) + 2 (the override
   shape). Shares `main.zig` with 3 — sequence after 3.
5. **`games/menu` controls screen + `rules.lua` remap flow** — *content*. A controls
   screen listing actions, each rebindable: on activate → `mana.capture_input`, on
   `on_input_captured` → validate + record the binding into handler-table fields + echo
   in the UI; Escape → `mana.cancel_capture`. Ties 1–4 together end-to-end. Depends on
   all of 1–4 and on the ADR-0039 multi-screen/focus-indicator gaps (#135/#209). Pure
   `games/` — no `src/` contention.

**Suggested ordering:** 1 and 2 in parallel (disjoint files) → 3 → 4 (both own
`main.zig`, so serialised) → 5 (content, last). An acceptance test in
`tests/` (the `menu_acceptance.zig` shape) proving capture → record → persist → reload →
live-swap end-to-end lands with 5 (or as its own gate issue).

Cross-references: #201 (this decision), #135 (settings-persistence precedent — the
driver seam this generalises, currently test-only), #209 (multi-screen/focus-indicator
gaps the controls screen needs), #190 (input epic), #192/#193 (action-map impl this
front-ends); builds on ADR 0040 (the action-map/`input.zon` this remaps — **§3 amended
here** to admit a user-override second file), ADR 0039 (UI input events + the UI-first
dispatch layer capture extends; §6 scoped capture out), ADR 0005 (hot-reload full-
reload/last-good/tick-boundary model reused for the map swap), ADR 0038 (package layout
— where `input.zon` and the `save/`-vs-config-dir override live), ADR 0021 (`on_key` —
the edge shape capture and `on_input_captured` copy), ADR 0003 (Lua scripting API —
§5 additive versioning, §7 sandbox that forces engine-side persistence, §9 error
policy), ADR 0009 (platform input port + input determinism/hash-exclusion).
