# games/menu

A navigable main menu + settings screen (issue #135; ADR 0034 UI subsystem, ADR 0039
UI input events). This package's only content IS that screen pair — proving the
widget/layout + focus-navigation + `on_click`/`on_focus`/`on_activate` dispatch built
in #182/#196 supports a real *interactive* UI, not just the display-only HUD #133's
Pac-Man anchor slice shipped.

**Layout:**
- `game.zon` — manifest (a trivial empty entry scene; this package has no gameplay).
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

**Known gap (not this issue's scope):** `Sim`/`src/runtime/main.zig` do not yet route
real keyboard/pointer input through `UiInput` in the interactive `--play` loop (today
only a display-only `hud` screen is wired end-to-end, via `manifest.hud`). This
package's screens are driven headlessly by the acceptance test; wiring an *active,
input-consuming* screen into the runner (so `mise run run -- games/menu --play` is
actually navigable) is a follow-up integration task.
