# 0039. UI input events: `on_click`/`on_focus`/`on_activate`

- Status: accepted
- Date: 2026-07-15

## Context

PR #182 shipped ADR 0034's Phase A (issue #134's first half): `src/ui/ui.zig` gained
pure, headless `hitTest`, `consumesPointer`, `focusOrder`, and `Focus`
(`next`/`prev`/`move`/`focusAt`) — pointer hit-testing and keyboard/gamepad focus
navigation, with no window and no script. It deliberately **stopped before wiring
event dispatch to Lua**: ADR 0034 §3 sketches `on_click`/`on_focus`/`on_activate` as
*direction* only, and its Consequences section explicitly defers "concrete
`mana`-surface UI events or handle types" to "#134, its own ADR per ADR 0003 §5."
ADR 0003 §5 is unconditional: *"Any change to the [scripting] surface … requires its
own ADR."* CLAUDE.md repeats it: *"One small, versioned scripting API … Every
addition needs an ADR."*

This issue (#183, split out of #134) is that ADR. It blocks the Phase B lane that
wires `src/script` dispatch on top of #182's primitives — no dispatch code should
land until the surface below is pinned. Per #183 this ADR fixes only the event names,
payload/handle shape, dispatch ordering, and determinism/versioning/sandbox
treatment; it does not implement any of it.

Forces already settled elsewhere, applied here rather than re-litigated:

- **Opaque handles, never raw pointers** (ADR 0003 §4) — a widget reference crossing
  into Lua cannot be a `*const ui.Widget`.
- **Event-driven, never per-frame per-widget** (ADR 0034 §3, restating ADR 0003's
  "Lua decides *what*; the engine executes *how*") — the engine dispatches; Lua never
  polls hit-test/focus state each frame.
- **UI is cosmetic and hash-excluded** (ADR 0034 §4) — layout, hover, and focus state
  never enter `World.stateHash`, the same category as `Appearance`/`Sprite`.
- **`on_key` precedent** (ADR 0021): a global, `self`-less, edge-driven event
  dispatched by diffing deterministic input, already established for keyboard; UI
  events extend the same shape rather than inventing a second one.
- **No speculative flexibility** (CLAUDE.md) — pin exactly what #183 asks for; leave
  mutator APIs (`mana.ui_set_text`, …) and multi-screen/modal stacking to a later,
  concretely-motivated ADR.

## Decision

### 1. Three new global events, added to ADR 0003 §3's table

`on_click`, `on_focus`, `on_activate` join `on_key` as event-driven, **`self`-less**
handlers (UI screens are not entities) — dispatched, like `on_key`, against the
**same single package/scene script handler table** that already receives
`on_scene_enter` (ADR 0017) and `on_key` (ADR 0021). No new script-attach point, no
per-widget script: a screen's ZON stays a pure layout/data description (ADR 0034 §2),
and interaction logic lives in the one place a package's event handlers already live.

| Handler | Signature | Fired when |
|---|---|---|
| `on_click` | `(ev)` — `ev = { widget, id, x, y }` | pointer press lands on a **hit widget** (`ui.hitTest`'s result — the topmost widget under the point, whether or not it is `focusable`; a background panel blocks and reports a click exactly as it blocks the point today via `consumesPointer`) |
| `on_focus` | `(ev)` — `ev = { widget, id }` | keyboard/gamepad focus **enters** a widget — any `Focus` transition to a new target, whether driven by `next`/`prev`, directional `move`, or pointer-driven `focusAt` (ADR 0034 §8's existing `Focus` API); only `focusable` widgets are ever a `Focus` target, so this event's domain is implicitly restricted to them |
| `on_activate` | `(ev)` — `ev = { widget, id }` | the currently focused widget (`Focus.current`) is activated — an `isActivateKey` **press edge** (enter/space going down), never on release, mirroring `on_key`'s press/release distinction |

`x`/`y` (screen pixels, the same space `ui.Rect`/`layout`'s viewport use) are
included only on `on_click`, where a pointer position is meaningful; `on_focus`/
`on_activate` carry none — nav-driven focus and key-driven activation have no
pointer coordinate.

### 2. Payload shape and the opaque widget handle

- `widget` is an **opaque packed handle** (`u32` widget-table index + `u32`
  generation → one 64-bit Lua integer), the exact bit-layout convention ADR 0003 §4
  already fixes for entities — reused for consistency, but drawn from a **separate
  widget-handle table**, never comparable or interchangeable with an entity handle.
  Passing a widget handle where an entity handle is expected (or vice versa) is a
  content bug: the host validates a handle's provenance and generation before ever
  dereferencing it, so a foreign or stale handle is always a safe nil/no-op, the same
  "never touch freed memory" guarantee ADR 0003 §4 requires — it is never a crash or
  UB, only ever an honest failure.
- **Handle lifetime:** the engine assigns indices by walking a `Screen`'s laid-out
  widgets in the same deterministic pre-order `layout`/`focusOrder` already produce,
  and bumps the generation once per `Screen` **load or hot-reload** (ADR 0005) — so a
  handle stays valid for every dispatch during one loaded screen's lifetime and
  becomes stale the instant that screen's ZON is hot-reloaded or unloaded, exactly
  like an entity handle going stale on despawn. Because there is no `mana.ui_*`
  accessor yet (§6), staleness has no observable failure mode in this ADR's scope —
  it is pinned now so the bit-layout doesn't need a version bump when accessors
  (`mana.ui_is_valid`, or similar) are added later.
- **`id`** is a new, optional, content-authored `Widget` field (`id: []const u8 =
  ""`, following the existing empty-string-sentinel convention `bind`/`text` already
  use — not `?[]const u8`) that Phase B adds to the ZON schema alongside the existing
  `bind`/`focusable` fields. It is how a script correlates an event to *which*
  widget fired without needing to enumerate the tree: `if ev.id == "start_button"
  then …`. An unauthored widget (`id = ""`) still gets a real handle and still fires
  events — it is simply not addressable by name, the same "anonymous but real" shape
  `bind = ""` already has for "not bound."
- **Handles are runtime-only** (ADR 0003 §4): never serialized to ZON/save, never
  compared by arithmetic — only by equality and against `id` for identification.

### 3. Dispatch ordering: UI first, gameplay only on what UI didn't consume

Per tick, the engine evaluates the active screen's `Focus`/hit-test state **before**
gameplay's own input handling and dispatches at most one consumer per input event:

- **Pointer:** if `ui.consumesPointer` is true for a press's point, the engine
  dispatches `on_click` (and updates `Focus` via `focusAt` when the hit widget is
  focusable) and the press is **not** additionally routed to any gameplay
  pointer/click path. If no widget is hit, the UI consumes nothing and the press
  falls through to gameplay untouched — today that is a no-op (no gameplay pointer
  input exists yet), but the rule is general so a future gameplay click handler
  composes correctly.
- **Keyboard:** while a screen with a focusable widget is active, an arrow-key press
  edge that `ui.navDirection` recognizes drives `Focus.move` (and fires `on_focus` on
  the new target) instead of reaching gameplay's `on_key` (ADR 0021) for that edge;
  an `isActivateKey` press edge fires `on_activate` instead of `on_key`. A key `on_key`
  does not map to (most keys, always, when no screen is active or nothing is
  focused) is dispatched to gameplay exactly as ADR 0021 already specifies — this ADR
  changes nothing about `on_key` itself, only inserts a UI-first refusal in front of
  it for the specific edges a screen's focus/activation machinery claims.
- This is the same "modal over what it covers" principle `consumesPointer`'s
  doc-comment already states for pointer input (src/ui/ui.zig); this ADR extends it
  to keyboard and makes it a dispatch-ordering rule, not just a hit-test predicate.

### 4. Determinism and state-hash exclusion

- **Excluded from `World.stateHash`:** exactly like `on_key`'s input stream (ADR 0021
  §4), the *occurrence* of `on_click`/`on_focus`/`on_activate` — and the `Focus`/
  hover/hit-test state that produces them — is cosmetic-adjacent UI state (ADR 0034
  §4) and never hashed. What *is* hashed, as always, is whatever gameplay-state
  mutation a handler body performs through the existing deferred command buffer (ADR
  0003 §2) — a click is a trigger, not a state fork.
- **Deterministic by construction:** the input stream driving pointer/key edges is
  already deterministic (ADR 0009/0021), `Focus` transitions are a pure function of
  that stream plus the laid-out tree, and widget-handle assignment is a pure function
  of a screen's deterministic pre-order (§2) — so the same input trace against the
  same content always produces the same dispatch sequence in the same order, the
  determinism-test bar every event source in this engine already meets.

### 5. Versioning and sandbox/error policy — inherited unchanged from ADR 0003

- **Purely additive:** three new handler keys and one new handle *kind* (not a new
  `mana` function, not a change to the existing entity-handle bit layout) — `mana.
  version` stays **1**. `id` is a new `Widget` field with a default (`= ""`, the same
  pattern every existing `Widget` field already uses, e.g. `bind`/`focusable`), so an
  older screen file authored before `id` existed still parses under `ui.parse`
  (`std.zon.parse.fromSliceAlloc`) and the widget simply comes back unaddressable by
  name — no `data.parseLenient` involved, since that helper is manifest-specific
  (`src/runtime/manifest.zig`), not something `ui.zig`'s `Screen`/`Widget` parsing
  uses.
- **Sandbox/error policy is exactly ADR 0003 §9**, unmodified: each dispatch call is
  `pcall`-wrapped; an error logs (with `debug.traceback`) and discards that
  invocation's command-buffer intent; the handler is disabled after the same N = 8
  circuit-breaker threshold, independently per handler key, and a hot reload of the
  script re-enables it. A `Screen` hot-reload (a *content* reload, distinct from a
  *script* reload) does not itself reset the circuit breaker — only the script side
  does, per §9 as already written.
- **Budget:** dispatch of these three events runs inside the same per-frame Tracy
  zone and 0.5 ms budget ADR 0003 §6 already fixes for all script dispatch; no
  separate UI budget is introduced.

### 6. Explicitly out of scope here (Phase B implementation's job, or later)

- No implementation: `src/script`, `src/ui`, `src/engine` are untouched by this ADR.
- No `mana.ui_*` query/mutator functions (e.g., reading a widget's current text,
  writing one) — nothing in #183 asks for them, and none is needed to fire these
  three events; add one only against a concrete future need, its own ADR per §5.
  No `mana.ui_is_valid`-style explicit staleness check either, for the same reason.
- No modal/overlay stacking (multiple simultaneously active screens racing for
  focus) — today's model is "the one active screen," matching what #182/#133 built;
  a stack is a later, concretely-motivated design.
- No `on_blur` (focus *leaving* a widget) or `on_hover` — #183 asks for exactly
  three events; add more only when a real screen needs them.
- No change to `ui.zig`'s existing `hitTest`/`consumesPointer`/`Focus` API shape —
  Phase B consumes it as-is; this ADR pins what wraps around it, not the primitives
  themselves.

## Alternatives considered

- **`on_click` restricted to `focusable` widgets only.** Rejected: #183's own wording
  is "pointer press on a hit widget," not "a focusable widget," and it matches the
  already-shipped `consumesPointer` semantics (any hit widget blocks the point,
  focusable or not) rather than introducing a second, narrower notion of "clickable."
  A script uncurious about a given `id` simply ignores the event, the same shape
  `on_collision_begin` already has (fires for any overlap; the handler decides
  relevance).
- **A per-widget/per-screen script attach point** (mirroring `.script` on a
  prototype). Rejected as unnecessary machinery: #182 built no such schema field, and
  reusing the one script table a package already has (the source of `on_scene_enter`/
  `on_key`) is strictly simpler, needs no manifest/schema change, and matches
  `on_key`'s existing "global, not per-entity" precedent. Revisit only if a concrete
  game needs independently-scriptable screens (CLAUDE.md's "second concrete impl
  planned, or don't abstract").
- **A fresh handle *namespace* indistinguishable from entity handles** (reuse
  `mana.is_valid`/the entity table directly). Rejected: widgets and entities have
  different lifetimes and live in different tables (`ui.Screen` vs `ecs.World`);
  collapsing them would make `mana.is_valid(some_widget_handle)` a plausible-looking
  call with undefined meaning. A same-shaped but distinct handle kind keeps the two
  honestly separate while reusing the proven bit-layout.
- **Including `x`/`y` on every event.** Rejected for `on_focus`/`on_activate`: neither
  is reliably pointer-driven (keyboard/gamepad nav has no pointer position), so a
  coordinate field would be frequently meaningless — dead weight the "small surface"
  discipline argues against.

## Consequences

- **Easier:** Phase B has an unambiguous, ADR-backed target — three handler keys, one
  payload shape each, one handle kind, one dispatch-ordering rule — so #134's
  remaining half is a wiring task against `src/ui`'s already-shipped, tested
  primitives, not a design task. A content author writes `on_click`/`on_focus`/
  `on_activate` in the same handler table as every other event they already know.
- **Harder / accepted:** the engine must maintain a second, screen-scoped handle
  table (distinct from the entity generation table) and reassign it deterministically
  on every screen load/hot-reload; the UI-first input-consumption rule (§3) is a new
  per-tick ordering the input dispatch path must implement correctly so a UI-consumed
  key/click never double-fires into gameplay.
- **Committed to (once accepted):** the event names, payloads, and handle semantics
  in §1–§2; the dispatch-ordering rule in §3; the hash-exclusion/determinism
  treatment in §4; `mana.version` unchanged at 1; the existing ADR 0003 §9 sandbox/
  error policy applied verbatim, with no UI-specific carve-out.
- **Explicitly not doing here:** see §6.

Cross-references: #183 (this decision), #134 (the issue this closes the design half
of), #182 (Phase A: `hitTest`/`consumesPointer`/`Focus`, the primitives this ADR
dispatches over); builds on ADR 0003 (Lua scripting API — event table, handle
semantics, versioning, sandbox/error policy), ADR 0009 (platform input port), ADR
0017 (`on_scene_enter`, the no-`self`/scene-level dispatch precedent), ADR 0021
(`on_key`, the global/edge-driven event this ADR's ordering rule composes with), ADR
0034 (UI subsystem direction — §3 sketches these handler names, §4 fixes the
cosmetic/hash-exclusion treatment this ADR applies to input events too).
