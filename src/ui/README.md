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

## Deferred: event dispatch to Lua (issue #134, other half)

ADR 0034 §3 sketches `on_click`/`on_focus`/`on_activate` as the shape UI interaction
will take, but its Consequences section explicitly leaves the concrete event names,
payloads, and any handle type **unpinned**, calling out that wiring them is "#134, its
own ADR per ADR 0003 §5's 'any change to the surface needs its own ADR'". Issue #134
itself repeats the same three names without an ADR reference. Per that discipline
(CLAUDE.md: "every scripting-API addition needs an ADR"), this module does not invent
that surface: hit-testing and focus navigation above are complete and reusable by
whatever dispatch mechanism a follow-on ADR pins, but calling into `script`/Lua for
`on_click`/`on_focus`/`on_activate` needs that ADR written and accepted first.

## Rendering (engine-side bridge)

The tree → GPU draw-list + text glyph emission (ADR 0034 §8, #133) lives in
`engine/render_ui.zig`, not here: it walks a laid-out `Screen`, emits flat `gpu.Quad`
panels and `gpu.SpriteQuad` label glyphs (via `engine/text.zig` + the embedded font
atlas from #131), and composites through `gpu.captureFrame`. It sits in `engine` because
the glyph atlas/text layout are engine-tier, keeping `ui` a font-free interpreter — the
same split `render.zig` uses. A label's text is sized to fit its rect height.

## Deferred (later phased slices, ADR 0034 §8)

Event dispatch to Lua (#134's other half, see above — needs its own ADR first),
styling/theming, `image` widget resolution, and intrinsic (text-driven) label sizing
(today a label's rect drives its text scale, not the reverse).
