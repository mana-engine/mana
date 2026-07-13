# 0030. Entity appearance as data: `.appearance` in the scene/prototype schema

- Status: accepted
- Date: 2026-07-13
- Amended: 2026-07-13 (Issue #101 — `shape` addendum, below)

## Context

Issue #98, filed against the headless SVG filmstrip ADR 0029 unblocked (PR #96): once
`games/pacman` could actually be *seen*, its render was unreadable. Two defects, both
in `src/engine/render.zig`'s `project`:

1. **Fixed quad size, not world-relative.** Every entity drew as an identical
   `view.quad_half_px` (16px half-extent, 32px square) regardless of its real size. The
   Pac-Man maze uses a one-world-unit grid at `scale = 24` (`games/pacman/game.zon`), so
   adjacent 32px quads on 24px-apart cell centres overlapped by 8px — walls, floor, and
   pickups smeared into one solid grid.
2. **Color by spawn index, not by kind.** `project` picked
   `default_palette[entity_index % palette.len]` — the next color in a fixed five-color
   cycle by *spawn order*, not by what the entity is. A wall, a dot, Pac, and a ghost
   spawned back-to-back got four unrelated colors; two dots two spawns apart could land
   on the same color by coincidence. No "walls blue, dots pale, Pac yellow" was
   expressible.

Both are a genre-neutral renderer gap, not a Pac-Man content bug (CLAUDE.md invariant
#6: "genre lives in content, not `src/`"): the fix must let *content* declare what an
entity looks like, the same way ADR 0025 let content declare a collider and ADR 0024
let content declare named data. `src/engine` must keep zero concept of "wall" or
"ghost" — only a generic appearance record.

## Decision

### A new component: `components.Appearance`

```zig
pub const Appearance = struct {
    color: [3]f32,   // RGB, each channel 0..1
    size: f32 = 1,   // full world-space width/height of the quad, world units
};
```

`color` replaces the palette-by-index pick for this entity. `size` is **world-space**,
not pixels: `render.project` multiplies it by the projection's pixels-per-world-unit
scale (a new `pxPerWorldUnit(proj)` — exactly `scale` for orthographic, `half_w` for
isometric, a pragmatic single scale for a square footprint since the emitter draws
axis-aligned rects, not diamonds), so a wall declaring `size = 1` fills a one-unit grid
cell and a dot declaring `size = 0.18` stays small, **regardless of the projection's
pixel scale** — the same content renders correctly whether `scale` is 24 or 240.
Defaults to `1` (a full unit cell), a reasonable value for a tile-based game that
declares nothing else.

This mirrors ADR 0025's shape exactly: one optional field threaded through the same
three call sites —

- **`components.Bundle`** (`appearance: ?Appearance = null`) — the set a deferred spawn
  attaches at flush (`command.zig`'s `attach` flush gains one line, after `nav_agent`).
- **`scene.EntityDef`** — `scene.load` calls `world.setAppearance(e, a)` when present.
- **`prototype.Prototype`** (`= scene.EntityDef`) — `bundleAt` carries `proto.appearance`
  through unchanged, like `collider`/`nav_agent`.

Plus a fourth site ADR 0025 also touches: **`tilemap.Tile.bundle`** — a legend cell's
`placeCell` now also applies `bundle.appearance`, so a tilemap-materialized wall (not
just a scene `entities` pickup or a `mana.spawn`-ed mover) can declare a look.

`World` gains an `appearances: ecs.SparseSet(Appearance)` column (parallel to
`colliders`/`nav_agents`) plus `setAppearance`/`getAppearance`, wired into `deinit`/
`despawn` like every other column.

### Renderer: `render.project` reads `Appearance` when present, else the old fallback

```zig
const appearance = world.appearances.get(entity_index);
const color = if (appearance) |a| a.color else palette[entity_index % palette.len];
const half_px = if (appearance) |a| (a.size / 2) * pxPerWorldUnit(view.projection) else view.quad_half_px;
```

An entity with **no** declared `Appearance` keeps the exact pre-existing behavior:
`palette[entity_index % palette.len]` and the fixed `view.quad_half_px` (still 16,
still `View`'s default). This is deliberate, not a hedge: it means every existing
package that has not opted in (`games/snake`, `games/sandbox`, the `scene_hello.zon`
determinism fixture) renders **byte-identically** to before this ADR — their render
goldens do not change, only Pac-Man's does (see below). "Engine renders what content
declares" degrades gracefully to the old genre-neutral default when content declares
nothing, rather than forcing every package to adopt appearance in the same PR.

### Why a dedicated `size` field, not derived from `Collider`

The issue text allowed either ("derive from the collider extent, and/or a dedicated
size field"). A dedicated field was chosen:

- **Render and physics extents are legitimately different concerns.** A Pac-Man dot's
  collider radius is tuned so *adjacent-cell* colliders never touch (0.4, ADR 0025's
  existing content) — reusing that as the visual size would draw dots as big as a
  ghost. The maze wall's collider (also 0.4) is deliberately smaller than the visual
  wall footprint (`size = 1`, a full cell) so the collider doesn't false-trigger nav
  blocking past the cell edge.
- **Not every appearance-worthy entity has (or should have) a collider.** A future
  purely-cosmetic entity (e.g. a particle placeholder) would need a fabricated collider
  just to be sized, coupling two unrelated systems.
- **Simplicity.** Deriving a scalar "size" from `physics.Shape`'s circle/capsule union
  needs a bounding-radius computation with its own edge cases (a capsule's long axis);
  a plain `f32` field has none, and is exactly the "minimal surface" the issue asked for.

### Pac-Man content: declares appearance, no `src/` change beyond the renderer

`games/pacman/prototypes.zon`: `pac` gets yellow (`{1.0, 0.9, 0.2}`); the single
`ghost` prototype is split into three — `ghost_red`, `ghost_pink`, `ghost_cyan` —
identical except `appearance.color`, since every ghost otherwise behaves the same and
`mana.spawn` cannot override a non-position field at the call site (ADR 0016: "a
variant is a second named prototype"). `rules.lua`'s `on_scene_enter` picks a name per
spawn index instead of the one literal `"ghost"`.

`games/pacman/scenes/maze.zon`: the tilemap legend's `'#'` bundle gains
`.appearance = .{ .color = .{0.15, 0.25, 0.75}, .size = 1 }` (a filled blue cell); each
pickup entity gains `.appearance` — pellets pale and larger (`size = 0.4`), dots pale
and small (`size = 0.18`), so the two pickup kinds read as visually distinct without a
new shape primitive (every quad is still a square; a circle/shape variant remains the
documented ADR 0029 §7 follow-up).

### Determinism: `Appearance` is cosmetic, excluded from the state hash

`World.stateHash` hashes `transforms`, `healths`, and `data` — unchanged by this ADR.
`appearances` is **not** added to it, the same treatment as `Velocity`/`Controller`/
`NavAgent`: a render-time hint no sim system reads, never mutated by a system, with no
effect on collision, pathfinding, or any other simulated behavior. A world test
(`world.zig`) pins this: attaching an `Appearance` to one of two otherwise-identical
worlds must not change `stateHash()`'s result. The pinned `tests/determinism.zig`
golden (`0x65f2a1949cd9fc40`) is confirmed unchanged by this PR's `mise run check`.

### Render-goldens: Pac-Man's changes, Snake's/sandbox's do not

`tests/fixtures/render_pacman_maze.svg` is regenerated (`MANA_UPDATE_GOLDENS=1`,
reviewed) — walls now render as filled 24px blue squares, dots/pellets as small pale
squares, matching their declared `Appearance`. `tests/fixtures/render_snake_board.svg`
is untouched: Snake declares no `Appearance`, so its render is byte-identical to
before, proving the fallback path (above) is exact, not approximate.

## Consequences

- **Pac-Man's headless filmstrip is finally readable**: walls read as a maze, pickups
  as small dots/pellets, pac and ghosts (once spawned) as distinct-colored pieces —
  the concrete need issue #98 named.
- **Any future package** gets the same tool for free: declare `.appearance` per
  prototype/scene-entity/tilemap-legend-cell, or declare nothing and keep the old
  palette-cycling default.
- **Committed to:** `Appearance`'s ZON shape is `color`/`size`/`shape` (below),
  nothing richer; `size` is a single scalar (footprint width/height), not per-axis;
  cosmetic and excluded from the state hash by policy, matching
  `Velocity`/`Controller`/`NavAgent`.
- **Explicitly not doing:** no script-side `mana`-surface change — a script cannot
  read or write `Appearance` (frightened-ghost re-tinting, mentioned as a future want
  in `games/pacman/prototypes.zon`'s comments, would need its own ADR if ever built);
  no per-instance appearance override at the `mana.spawn` call site (ADR 0016's
  existing constraint — a variant is a second named prototype, which is what the
  three ghost prototypes demonstrate); no derivation from `Collider` (see rationale
  above).

## Addendum (Issue #101): `shape` — a second cosmetic field, same treatment as `color`/`size`

The "no shape field" line above was this ADR's documented ADR-0029-§7 follow-up; issue
#101 is that follow-up. `Appearance` gains one more field:

```zig
pub const Appearance = struct {
    color: [3]f32,
    size: f32 = 1,
    shape: gpu.Shape = .rect, // NEW
};
```

`gpu.Shape` (`src/gpu/types.zig`) is a small, genre-neutral enum: `rect` (default,
preserves every existing look/golden byte-for-byte) and `circle`. It lives in `gpu`
alongside `Quad` — the same plain-data vocabulary the null/Vulkan backends already
consume — rather than in `src/engine`, so `gpu.Quad` itself grows a `shape: gpu.Shape
= .rect` field `render.project` sets from the entity's `Appearance` (or `.rect` when
absent, matching the existing color/size fallback).

**No new plumbing at the four call sites.** Unlike `color`/`size` (ADR 0030's original
threading work), `shape` needed zero changes to `components.Bundle`, `scene.EntityDef`,
`prototype.Prototype`, or `tilemap.Tile.bundle` — all four already carry `Appearance`
through as one opaque struct (`bundle.appearance`, `proto.appearance`, …), so a new
field on `Appearance` rides along automatically. Only the renderer changed:
`render.project` copies `appearance.shape` onto the quad, and `render_svg.toSvg`
switches on `gpu.Quad.shape` to emit an `<ellipse>` instead of a `<rect>` for
`.circle`-shaped quads (`src/engine/render_svg.zig`).

**`polygon` deferred, not built.** The ghost silhouette (a dome + skirt) was the
motivating case for a third variant, but a polygon needs a vertex-list shape (SVG
`<polygon>`, plus a GPU-side triangulation the quad rasterizer doesn't have) — genuinely
new surface, not a drop-in enum value. `games/pacman` renders ghosts as `.circle`
instead (a `-- TODO(#101 follow-up)` marks the spot in `games/pacman/prototypes.zon`).
Per CLAUDE.md ("no speculative flexibility"), `polygon` is not added to `gpu.Shape`
until a concrete need re-justifies it.

**Vulkan/null backend unaffected.** `gpu.Quad.shape` is read only by `render_svg.zig`
today; `buildVertices` (`src/gpu/gpu.zig`) still rasterizes every quad as its bounding
rect regardless of `shape` — true circle/polygon geometry on the GPU path is future
work, not required by this issue (which only asked for headless/SVG legibility).

**Determinism unchanged.** `shape` is one more field on the already-excluded
`Appearance`/`Bundle.appearance` — the `stateHash` exclusion and its pinning test
(`world.zig`, "an appearance does not perturb the state hash") cover it without
modification; the pinned `tests/determinism.zig` golden (`0x65f2a1949cd9fc40`) is
unchanged by this addendum's `mise run check`.

**Render-goldens:** `tests/fixtures/render_pacman_maze.svg` is regenerated
(`MANA_UPDATE_GOLDENS=1`, reviewed) — the static scene's dots and pellets now draw as
`<ellipse>`s; walls stay `<rect>`s (declare no `shape`, default `.rect`). Pac and the
ghosts carry `.shape = .circle` on their prototypes (unit-tested in
`src/engine/prototype.zig`), but they are *script-spawned* by `rules.lua`'s
`on_scene_enter` — and `--render-svg` deliberately renders the static scene without
ticking or running the package script (`src/runtime/main.zig`), so they do not appear
in this fixture at all. `tests/fixtures/render_snake_board.svg` is untouched (Snake
declares no `Appearance` at all).
