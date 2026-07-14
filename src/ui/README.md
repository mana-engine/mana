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

## Deferred (later phased slices, ADR 0034 §8)

GPU draw-list emission + text/glyph metrics (#131/#133), input focus + event routing to
Lua (#134), styling/theming. Widget sizing here is explicit-or-flex; text does not yet
drive intrinsic label size (needs the font metrics from #131).
