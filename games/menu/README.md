# games/menu

A navigable main menu + settings screen (issue #135; ADR 0034 UI subsystem, ADR 0039
UI input events). This package's only content IS that screen pair — proving the
widget/layout + focus-navigation + `on_click`/`on_focus`/`on_activate` dispatch built
in #182/#196 supports a real *interactive* UI, not just the display-only HUD #133's
Pac-Man anchor slice shipped.

**Layout:**
- `game.zon` — manifest (a trivial empty entry scene; this package has no gameplay).
  Its `.hud = "screens/main_menu.zon"` (issue #209) doubles the front screen as the
  runner's `hud`: `--play` both renders it and routes keyboard focus-nav/activate
  presses into it (ADR 0039 §6's "one active screen"), so `mise run run --
  games/menu --play` is navigable in a real window.
- `screens/main_menu.zon` / `screens/settings.zon` — the two `ui.Screen` widget trees
  (ADR 0034 §2): vertical button stacks, navigable with up/down, activated with enter.
- `scripts/rules.lua` — `on_focus`/`on_click`/`on_activate` handlers; settings values
  (`volume`/`difficulty`) live here as plain Lua state, mirrored onto the handler
  table so an engine-side driver can read them (`handlerFieldInt`) and persist them.
- `save/settings.zon` — the shipped default user-preference values (files are the
  source of truth, invariant #1); a driver overwrites this file (via the new
  `data.zon.saveFile`/`loadFile` engine primitive, issue #135) whenever a setting
  changes.

See `tests/menu_acceptance.zig` for the headless acceptance proof: navigate → focus
→ activate → settings value changes → persists to ZON → reloads — driving the exact
`ui_dispatch.UiInput` / `script_runtime.Runtime` primitives #196 shipped, against a
real Lua interpreter, no window.

**Known gaps (not this issue's scope, #209):**
- **No visual focus indicator.** `ui.Widget` has no "focused" styling hook, so a
  human playing `--play` can navigate (arrow keys move `Sim.ui_input.focus.current`,
  enter activates) but sees no on-screen highlight of which button is focused. Adding
  one is a widget/content change, deliberately out of #209's scope.
- **No screen switching.** Activating "SETTINGS" fires `on_activate` and mutates the
  Lua handler table's `next_screen` field exactly as `tests/menu_acceptance.zig`
  observes, but nothing in the runner reacts to it by swapping `sim.ui_input`'s active
  screen to `settings.zon` — that swap is driven manually by the headless test today.
  A generic "the runner reacts to a content-declared screen transition" mechanism is
  future work, not this issue's (single active screen, ADR 0039 §6) scope.
- **Pointer/click routing is not wired in `--play`** — #209 is keyboard-only
  (`Sim.ui_input.keyEdge`); `UiInput.pointerPress` exists and is tested, but nothing
  in `runtime/main.zig` feeds it a mouse position yet.
