# games/menu

A navigable main menu + settings + **controls (remap)** screen (issues #135/#239; ADR
0034 UI subsystem, ADR 0039 UI input events, ADR 0041 in-game remap). This package's
only content IS those screens — proving the widget/layout + focus-navigation +
`on_click`/`on_focus`/`on_activate` dispatch built in #182/#196 supports a real
*interactive* UI, not just the display-only HUD #133's Pac-Man anchor slice shipped,
and (since #239) that ADR 0041's whole remap chain works from a player's chair:
**capture → validate → record → persist → reload → live-swap**.

**Layout:**
- `game.zon` — manifest (a trivial empty entry scene; this package has no gameplay).
  Its `.hud = "screens/main_menu.zon"` (issue #209) doubles the front screen as the
  runner's `hud`: `--play` both renders it and routes keyboard focus-nav/activate
  presses into it (ADR 0039 §6's "one active screen"), so `mise run run --
  games/menu --play` is navigable in a real window.
- `screens/main_menu.zon` / `screens/settings.zon` — two of the three `ui.Screen` widget
  trees (ADR 0034 §2): vertical button stacks, navigable with up/down, activated with
  enter.
- `scripts/rules.lua` — `on_focus`/`on_click`/`on_activate`/`on_input_captured`
  handlers; settings values
  (`volume`/`difficulty`) live here as plain Lua state, mirrored onto the handler
  table so an engine-side driver can read them (`handlerFieldInt`) and persist them.
- `save/settings.zon` — the shipped default user-preference values (files are the
  source of truth, invariant #1); a driver overwrites this file (via the new
  `data.zon.saveFile`/`loadFile` engine primitive, issue #135) whenever a setting
  changes.
- `input.zon` — the package action map (ADR 0040 §3): the three digital `button`
  actions the controls screen rebinds. Shipped, pristine content; a player rebind never
  touches it.
- `screens/controls.zon` — one focusable row per action, activated to arm
  capture-next-input for it.
- `save/input.zon` (**not shipped — engine-written**) — the user override (ADR 0041 §2)
  the persistence driver writes when `rules.lua` accepts a rebind, merged OVER
  `input.zon`, override-wins, per-action. Absent by default, which is why the package
  boots on its defaults.

## The remap chain (ADR 0041, issue #239)

1. Activating a rebind row → `mana.capture_input(action)` arms the engine's capture mode.
2. The next physical **press edge** (key or pad button) is intercepted and delivered as
   `on_input_captured{action, source}` — never reaching focus nav or `on_key`.
3. `rules.lua` validates it (rejecting a key the menu's own UI claims, or one already
   bound to another action), records the accepted `source` in its `bindings` handler
   field **verbatim**, and bumps `bindings_revision`.
4. The engine-side driver (`src/engine/input_override.zig`) polls that revision, and on
   a bump writes `save/input.zon`. **The file is the channel**: no bump ⇒ no write, and
   no write ⇒ no apply.
5. The watcher sees the file change, re-merges it over `input.zon`, and swaps the live
   action map at a tick boundary. Persist and apply are one motion.

Two consequences worth knowing before authoring a controls screen:

- **A rebind replaces the action's WHOLE binding** (per-action replace, ADR 0041 §2), so
  rebinding FIRE to `D` drops its gamepad default too. v1 captures one source per rebind.
- **`source` is asymmetric** (ADR 0041 §1.1): keys arrive bare (`"w"`), pad buttons
  `pad_`-prefixed (`"pad_south"`). Content passes both through **untouched** — the driver
  owns the translation into `keys`/`pad_buttons`.

Only **digital** sources are rebindable: v1 capture defers analog (stick/trigger)
sources, so every action here is a `button`.

See `tests/menu_acceptance.zig` for the headless acceptance proofs, against a real Lua
interpreter, no window:
- navigate → focus → activate → settings value changes → persists to ZON → reloads,
  driving the exact `ui_dispatch.UiInput` / `script_runtime.Runtime` primitives #196
  shipped;
- the remap chain above, driven through a real `Sim` — the same object `--play` ticks —
  from a key edge all the way to a rebound action firing off the swapped map, for both a
  key and a gamepad button.

**Known gaps the remap content ran into (#239; each is engine work, not content's):**
- ~~**A captured press still reaches gameplay `on_action`.**~~ **Closed by #246 (press)
  and #256/#213 (release).** ADR 0041 §1 says an intercepted edge reaches neither
  `on_key` nor `on_action`. #246 first closed the press half — the action-edge loop
  diffs against a per-tick snapshot with every UI-claimed key/pad-button edge masked
  out, so a bound key or pad button pressed while capture is armed no longer also
  fires its action on the press edge. That left a second leak: `keyEdge`/
  `padButtonEdge` only ever claim a *press* (never a release, ADR 0041 §1.1), so a
  UI-consumed press's later release edge still reached `on_action`/`on_key`
  unbalanced (`Sim.prev_input` stayed raw while the resolver diffed the masked
  snapshot, so the up-transition still registered) — the same root cause on both the
  `on_action` path (#256) and `on_key`'s pre-existing release asymmetry (#213).
  Fixed together with a **latched mask**: `Sim.consumed_keys`/
  `consumed_pad_buttons` remember which sources the UI consumed a press for and keep
  masking them until they physically release, instead of only masking the press
  tick. `tests/menu_acceptance.zig` (this content's own acceptance staircase)
  continues to assert the press half for both source vocabularies; the release half
  — invisible to `rules.lua`'s `on_action`, which discards releases at the script
  layer (`if not ev.pressed then return end`) — is asserted directly in
  `src/engine/sim.zig`'s `Sim.tick` tests, for both `on_action` and `on_key` and both
  source vocabularies.
- ~~**A script cannot read back its own persisted override.**~~ **Closed by #247** (ADR
  0041 §4 amendment). Lua still has no filesystem (ADR 0003 §7), but the engine now
  *seeds* `bindings` from `save/input.zon` at script load and after each reload
  (`input_override.seedBindings`, dispatched from `runtime/main.zig`'s
  `syncScriptBindings`), so `rules.lua` starts each session holding what is really
  persisted. That is what makes the whole-override write safe across sessions — it used
  to drop the previous session's rebinds — and lets `bound_elsewhere` validate against
  LIVE bindings. The `DEFAULT_KEYS`/`DEFAULT_PAD` mirrors remain, and still need the
  drift test: the seed carries the *override*, never the package defaults (seeding the
  merged map would freeze today's defaults into the player's file forever). One residue,
  logged rather than silent: a *hand-edited* override entry binding several sources to one
  action can't fit the script's one-source-per-action field, so it applies but won't
  survive the next rebind — the remap UI cannot produce such an entry.
- ~~**No live echo of the current binding.**~~ **Closed by #248**: `engine/ui_host.zig`
  fills the `ui.Host` seam from the script's handler table, so a `bind = "bindings.<action>"`
  reads the live accepted source out of `rules.lua`'s `bindings` field — the same field the
  persistence driver writes `save/input.zon` from. `screens/controls.zon`'s binding cells
  use it; each row's `text` is the shipped default, which `ui.boundValue` still falls back
  to while the player has not overridden that action (correct: that IS its binding). The
  runner installs it in front of `render_ui.worldHost` (`projectHud`), so one screen can
  bind both a numeric world component and a script string.

**Known gaps (not this issue's scope, #209):**
- **No visual focus indicator.** `ui.Widget` has no "focused" styling hook, so a
  human playing `--play` can navigate (arrow keys move `Sim.ui_input.focus.current`,
  enter activates) but sees no on-screen highlight of which button is focused. Adding
  one is a widget/content change, deliberately out of #209's scope.
- **No screen switching.** Activating "SETTINGS"/"CONTROLS" fires `on_activate` and mutates the
  Lua handler table's `next_screen` field exactly as `tests/menu_acceptance.zig`
  observes, but nothing in the runner reacts to it by swapping `sim.ui_input`'s active
  screen to `settings.zon` — that swap is driven manually by the headless test today.
  A generic "the runner reacts to a content-declared screen transition" mechanism is
  future work, not this issue's (single active screen, ADR 0039 §6) scope.
- **Pointer/click routing is not wired in `--play`** — #209 is keyboard-only
  (`Sim.ui_input.keyEdge`); `UiInput.pointerPress` exists and is tested, but nothing
  in `runtime/main.zig` feeds it a mouse position yet.
