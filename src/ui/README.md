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

## Rendering (engine-side bridge)

The tree → GPU draw-list + text glyph emission (ADR 0034 §8, #133) lives in
`engine/render_ui.zig`, not here: it walks a laid-out `Screen`, emits flat `gpu.Quad`
panels and `gpu.SpriteQuad` label glyphs (via `engine/text.zig` + the embedded font
atlas from #131), and composites through `gpu.captureFrame`. It sits in `engine` because
the glyph atlas/text layout are engine-tier, keeping `ui` a font-free interpreter — the
same split `render.zig` uses. A label's text is sized to fit its rect height.

## Deferred (later phased slices, ADR 0034 §8)

Input focus + event routing to Lua (#134), styling/theming, `image` widget resolution,
and intrinsic (text-driven) label sizing (today a label's rect drives its text scale, not
the reverse).
