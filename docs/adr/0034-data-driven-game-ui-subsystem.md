# 0034. Data-driven game-UI subsystem: direction

- Status: proposed
- Date: 2026-07-14

## Context

No first-class game-UI exists. `zgui` (Dear ImGui) is wired for `tools/` and debug
overlays only — CLAUDE.md is explicit that ImGui never reaches game UI. Once a game
needs a HUD, menu, settings screen, or inventory panel (Pac-Man's score/lives, the
North-Star games generally, issue #62/#129), that content has nowhere to live: it is
neither sim state (it's cosmetic display) nor a debug overlay (it's a player-facing
feature). Issue #130 asks for the *direction* — module boundary, data vs. Lua split,
and determinism treatment — before any concrete widget/schema work starts, the same
way ADR 0003 fixed the scripting API's shape before `src/script` was built.

The forces in tension, all already settled by existing invariants that this ADR must
apply rather than re-litigate:

- **Invariant #1** (files are the source of truth, editors are optional clients) and
  **"prefer data over Lua"** push UI *structure* toward declarative content, not
  imperative code.
- **"ImGui only in `tools/`, never game UI"** rules out building game UI on `zgui`
  outright — reinforced by **"never build a common interface over libraries with
  different shapes (e.g. UI libs)"**: `zgui`'s immediate-mode, per-frame-call shape is
  not the shape a hot-reloadable, headless-testable, node-graph-targetable UI needs.
- **The physics/VFX invariant** ("deterministic within the sim, or cosmetic and
  excluded from the state hash") has no UI analogue yet, and needs one: a HUD reads
  sim state but must not become a second copy of it.
- **"Lua decides *what*; the engine executes *how*," never a per-frame per-entity (here,
  per-widget) callback** — the same rule ADR 0003 applied to entities applies to
  widgets.
- No text/font rendering capability exists at all (`gpu` has no glyph path); any HUD
  design that ignores this ships nothing real.

## Decision

### 1. Game UI is content, not `zgui`

`zgui` stays a `tools/` + debug-overlay dependency exactly as CLAUDE.md already
states; this ADR does not change that boundary, it reaffirms it as the starting
premise. Game-facing UI (HUD, menus, settings, inventory) is a new **engine-owned,
data-interpreted subsystem**, unrelated to `zgui`'s API or rendering model.

**Alternative rejected: build game UI on `zgui`.** Immediate-mode ImGui is designed
for editor/debug chrome (per-frame calls, no persistent scene graph, no headless
output), not for content a game package authors as data and hot-reloads. Adopting it
for game UI would violate two invariants at once — "ImGui never reaches game UI" and
"never build a common interface over UI libraries with different shapes" — and would
couple shippable games to a debug-tool dependency.

### 2. UI structure is declarative ZON, engine-interpreted

A UI screen (HUD layout, a menu, a settings panel) is a **widget/layout tree
expressed in ZON**, loaded and interpreted by the engine the same way scenes,
prototypes, and node graphs already are (ADR 0004, ADR 0018). This gets UI for free
everything content already has: hot reload (invariant #2), diffability, a future
node-graph editing target, and — the requirement with no existing precedent in this
codebase — **headless testability**: the null backend must be able to assert layout,
hit-test, and focus results without a window, the same way the null `gpu` backend is
a real rasterizer, not a no-op (ADR 0010 §3).

**Alternative rejected: imperative UI authored in Lua or Zig.** Either would work
technically, but both violate "prefer data over Lua" and invariant #1 — an imperative
build-the-tree-in-code UI is not diffable, not a node-graph target, and re-derives
hot-reload machinery the data path gets for free. This ADR does not pin the ZON
schema itself (widget types, layout algebra, styling) — that is #132's job.

### 3. UI behavior is Lua, event-driven — never per-frame per-widget

Interaction logic (a button's `on_click`, a field's `on_focus`, a panel's `on_open`)
is scripted, using the **same event-dispatch model ADR 0003 already defines**: the
engine calls a handler key if present; Lua never iterates or polls widgets each
frame. This is not a new scripting mechanism — it is ADR 0003's event list gaining
UI-shaped members (exact event names/payloads are #134's job, when input focus and
routing are built) — and it inherits ADR 0003's existing guarantees for free: opaque
handles, deferred/transactional mutation, sandboxing, the error/circuit-breaker
policy, and the per-frame script budget.

### 4. UI is an edge: rendered via `gpu`, input via `platform`, cosmetic and hash-excluded

UI is a **port-tier concern**, not sim logic. It renders through the `gpu` port
(invariant #4: nothing above `gpu` touches Vulkan) and receives input through the
`platform` port (ADR 0009), exactly like the existing scene renderer and the
character controller's input path.

Applying the physics/VFX determinism invariant to UI: **UI presentation is cosmetic
and excluded from `World.stateHash`**, in the same category as `Appearance` (ADR
0030) and `Sprite`/`AnimationState` (ADR 0031). A widget tree's layout cursor, focus
state, animation/transition timers, and hover state never enter the hash. What *is*
simulated and hashed is the **gameplay state the UI displays** — score, lives,
inventory contents, health — which already lives in sim/ECS data (ADR 0024's named
data components, or dedicated components) exactly as it would if no UI existed. The
UI subsystem **binds** to that data one-way (sim/ECS state → displayed widget); it
never becomes a second source of truth for it, and nothing in the UI layer writes
gameplay state directly — a click that should affect gameplay goes through the same
`mana` API and command buffer any other script mutation does (§3, ADR 0003 §2).

### 5. A new `ui` module, at the port tier

`ui` joins the module DAG alongside the other ports, not above `engine`:

```
ui → core + data + ecs + gpu + platform
engine → core + data + ecs + gpu + physics + platform + script + ui
```

`ui` depends on `ecs`/`data` directly (to read the bound sim state) and on `gpu`/
`platform` (to draw and receive input) — the same tier `script` already occupies, for
the same reason: it is a capability `engine` orchestrates on every tick, not a
consumer of `engine`. `engine` gains one new import (`ui`) to its existing list; `ui`
never imports `engine`, so the DAG stays acyclic. `runtime` and `tools` see `ui` only
indirectly through `engine`, matching how they already reach `gpu`/`platform`/
`script` today.

### 6. Prerequisite: text/font rendering does not exist yet

No glyph atlas, font loader, or text-layout path exists anywhere under `gpu` or
`engine` today. This is the **load-bearing first dependency** (#131): a UI subsystem
that cannot render text cannot ship a real HUD, menu, or inventory label — only
colored rects. The phased build (below) puts it first for exactly this reason; it is
called out here so no later slice is designed as if text rendering already existed.

### 7. Tools may ride mana-UI later; interim tool chrome stays `zgui`

Once the `ui` subsystem is mature enough to support editor-grade chrome (Godot's
own editor is built on Godot's UI toolkit, not a separate one), `tools/` may migrate
onto it. That is a future, separately-justified decision (CLAUDE.md: "second concrete
impl planned, or don't abstract" — today there is exactly one, unproven,
implementation of `ui`). Until then, `tools/` keeps using `zgui` for editor/debug
chrome, unchanged. This resolves the latent "should tools build on the engine's own
UI" question raised by this subsystem's existence: not yet, and not by default.

### 8. Phased build, anchored on a real slice

The subsystem ships in dependency order, each its own issue/ADR-as-needed:

**#131** (text/font rendering, the `gpu`-port prerequisite) → **#132** (the
declarative widget/layout ZON format + engine interpreter) → **#133** (first anchor
slice: **Pac-Man score/lives HUD** — display-only, no input/focus needed) → **#134**
(input focus + routing: hit-testing, focus nav, event dispatch to Lua, which is where
§3's event list gets pinned) → **#135**/**#136** (navigation and data-bound-grid
slices: a menu/settings screen, an inventory panel).

**#133 is the anchor**, not a toy: display-only score/lives text bound to Pac-Man's
existing sim state is the smallest slice that exercises invariant #6 ("genre lives in
content, not `src/`") — the HUD is a `games/pacman` content artifact, and `src/ui`
gains zero Pac-Man-specific concept from building it, the same discipline ADR 0030/
0031 already applied to appearance and sprites.

## Consequences

- **Easier:** a game gets HUD/menu/inventory content the same way it gets scenes and
  prototypes — hot-reloadable ZON plus event-driven Lua — with no new mental model;
  UI logic inherits ADR 0003's sandboxing, budget, and error policy for free; UI
  bugs are headlessly reproducible (layout/hit-test/focus assertable without a
  window), matching the null-backend-is-a-real-adapter discipline already used for
  `gpu` and physics.
- **Harder / accepted:** nothing ships until text rendering (#131) exists — there is
  no way to shortcut a real HUD with colored rects and call it done; `ui` is a new
  module every future `engine` change must keep acyclic against; UI's "cosmetic,
  hash-excluded, one-way bound" discipline must be enforced the same way `Appearance`/
  `Sprite` are, or a HUD becomes a silent second source of truth for gameplay state.
- **Committed to:** `ui → core + data + ecs + gpu + platform`, with `engine` the only
  importer of `ui`; UI structure as ZON, UI behavior as Lua events, never a per-frame
  per-widget callback; UI state excluded from `World.stateHash`; `zgui` remains
  `tools/`-only for the foreseeable future.
- **Explicitly not doing here:** no concrete widget/layout ZON schema (#132), no
  concrete `mana`-surface UI events or handle types (#134, its own ADR per ADR 0003
  §5's "any change to the surface needs its own ADR"), no font/glyph format decision
  (#131), no styling/theming model. This ADR fixes the *shape and constraints* the
  later, narrower ADRs must fit — not the field lists.

Cross-references: #130 (this decision), #131 (text/font rendering, prerequisite),
#132 (widget/layout ZON format), #133 (Pac-Man HUD, anchor slice), #134 (input focus/
routing), #135/#136 (navigation and data-bound-grid follow-ups); builds on ADR 0003
(Lua scripting API/event model), ADR 0004 (scene/entity schema), ADR 0009 (platform
port), ADR 0010 (gpu port surface), ADR 0018 (a game is data), ADR 0024 (named data
components), ADR 0030 (appearance as data / cosmetic-hash-exclusion precedent), ADR
0031 (sprite rendering, the other cosmetic-and-hash-excluded precedent).
