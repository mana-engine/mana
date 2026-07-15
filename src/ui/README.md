# src/ui — data-driven game UI (ADR 0034)

Game-facing UI (HUD, menus, panels) as **content**, not code: a widget/layout tree
authored in ZON and interpreted here. This is the Phase 1 spine (issue #132) — the pure
interpreter, headless-testable, no window.

## Tier (ADR 0034 §5)

```
ui → core + gpu + platform
engine → … + ui   (engine is the sole importer)
```

`ui` imports **no `ecs`/`data`** — a `ui → ecs` edge is a build error by design — and
names **no Vulkan type**. It reaches live gameplay state only through the `Host` seam
(ADR 0015 pattern), which `engine` fills from the live `Sim`. UI presentation is
**cosmetic and excluded from `World.stateHash`** (ADR 0034 §4), in the same category as
`Appearance`/`Sprite`.

## Surface (this slice)

- `parse` / `free` — a ZON `Screen` (a named `root` `Widget`) in, engine structs out.
  Hot-reload friendly: re-parse a file into a fresh `Screen`, no global state.
- `layout(gpa, screen, viewport) -> []Placed` — pure geometry: each widget's screen
  `Rect`, in paint (pre-order) order. Supports **flex** (row/column, `gap`, `padding`,
  leftover space split among unsized children) and **anchor** (a 3×3 grid) layout.
- `hitTest(placed, x, y) -> ?*const Widget` — point → topmost widget (reverse paint scan).
- `Host` + `boundValue` — one-way data binding: a widget's `bind` name is read through
  the host (sim/ECS state → widget); the UI never writes gameplay state through it.
- `Widget.focusable`, `focusOrder`, `Focus` (`next`/`prev`/`move`/`focusAt`),
  `consumesPointer`, `navDirection`/`isActivateKey` — hit-testing and keyboard/gamepad
  focus navigation (issue #134, hit-test/focus half). `Focus` tracks which focusable
  widget currently has input, walked via a deterministic paint-order focus list or
  screen-space directional nearest-neighbor; `consumesPointer` tells a caller a click
  landed on the UI at all, so input can be routed to the UI **before** gameplay input.
  All pure and headless-testable, no window, no script.

## File layout (issue #151)

`ui.zig` crossed the ~500-line soft limit (807 lines) without the room to split it that
this file's own former "kept as one file for now" note assumed. The maintainer follow-up
on #151 identified the real seam: pull the shared leaf types (`Rect`/`Widget`/`Placed`/
`hitTest`, plus `parse`/`layout`/`focusOrder`) into a sibling `types.zig`, so both
`ui.zig` and a new `focus.zig` (`Focus`/`NavDirection`/`navDirection`/`isActivateKey`)
import it without either importing the other back. `ui.zig` re-exports both, so the
public API (`ui.Widget`, `ui.layout`, `ui.Focus`, …) is unchanged; it now holds only the
`Host` seam and `boundValue`, which don't fit either sibling.

## Event dispatch to Lua (issue #134, other half — engine-side)

`on_click`/`on_focus`/`on_activate` are pinned by **ADR 0039 (accepted)** and wired in
`engine/ui_dispatch.zig`, one tier up: it consumes the hit-test/focus primitives above,
applies the ADR 0039 §3 "UI consumes input before gameplay" ordering, and dispatches the
three events to the Sim's Lua handler table. `ui` itself stays the pure interpreter and
names no Lua/handle type — its only contribution to that surface is the content-authored
`Widget.id` (ADR 0039 §2), the stable name a handler correlates a UI event against.

## Rendering (engine-side bridge)

The tree → GPU draw-list + text glyph emission (ADR 0034 §8, #133) lives in
`engine/render_ui.zig`, not here: it walks a laid-out `Screen`, emits flat `gpu.Quad`
panels and `gpu.SpriteQuad` label glyphs (via `engine/text.zig` + the embedded font
atlas from #131), and composites through `gpu.captureFrame`. It sits in `engine` because
the glyph atlas/text layout are engine-tier, keeping `ui` a font-free interpreter — the
same split `render.zig` uses. A label's text is sized to fit its rect height.

## Deferred (later phased slices, ADR 0034 §8)

Styling/theming, `image` widget resolution, and intrinsic (text-driven) label sizing
(today a label's rect drives its text scale, not the reverse). Event dispatch to Lua
(#134's other half) is done — see the section above and `engine/ui_dispatch.zig`.
