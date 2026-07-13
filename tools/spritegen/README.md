# spritegen — procedural sprite generator

A standalone, **genre-neutral** dev tool (ADR 0031). It reads a ZON *sprite recipe* and
deterministically rasterizes it into two **derived** artifacts:

- `<name>.msf` — the sprite-sheet asset (MSF1: raw RGBA8 frames + a clip table; the
  engine decodes it — Lane B).
- `<name>_preview.png` — a human-viewable montage of the frames over a checkerboard.

Neither is committed. The **recipe** (`.zon`) is the source of truth (CLAUDE.md
invariant #1); sheets are pure functions of it and are gitignored
(`**/sprites/generated/`). The tool contains **zero game knowledge** (invariant #6):
`pac`, `ghost`, `snake segment`, `food` are recipe *files* under a game package, not
code here — the tool knows only generic primitives.

## Run and view (cross-platform)

Generate every committed recipe into its gitignored `generated/` dir:

```
mise run assets
```

Or generate one recipe into a dir of your choice:

```
mise run spritegen -- games/pacman/sprites/pac.zon games/pacman/sprites/generated
```

Both are a single `zig build` invocation — identical on Linux and Windows (no shell
syntax). Then open the preview in any browser / OS image viewer:

| OS | Command |
|----|---------|
| Linux | `xdg-open games/pacman/sprites/generated/pac_preview.png` |
| macOS | `open games/pacman/sprites/generated/pac_preview.png` |
| Windows | `start games\pacman\sprites\generated\pac_preview.png` |

You will see the four pac frames chomping (mouth shut → wide open).

## Recipe format

A recipe is a single ZON struct. Coordinates are **normalized 0..1** over a square
canvas (`(0,0)` top-left, `(1,1)` bottom-right; y grows downward). Radii and lengths
use the canvas width as their unit, so a recipe is resolution-independent.

```zon
.{
    .size = 32,                 // canvas edge in pixels (square)
    .palette = .{               // named straight-alpha RGBA8 colours
        .{ .name = "pac", .rgba = .{ 255, 221, 51, 255 } },
        .{ .name = "clear", .rgba = .{ 0, 0, 0, 0 } },  // a==0 ⇒ the ERASE colour
    },
    .background = null,         // a palette name to clear each frame to, or null = transparent
    .frames = .{                // ordered frames; each is an ordered op list (painter's order)
        .{ .name = "open", .ops = .{
            .{ .disc = .{ .cx = 0.5, .cy = 0.5, .r = 0.46, .color = "pac" } },
            .{ .wedge = .{ .cx = 0.5, .cy = 0.5, .r = 0.52, .a0 = -50, .a1 = 50, .color = "clear" } },
        } },
    },
    .animations = .{            // named clips: frame indices + playback rate
        .{ .name = "chomp", .fps = 12, .frames = .{ 0, 1, 2, 3, 2, 1 } },
    },
}
```

A colour named in an op must exist in the palette. Painting with a **fully transparent**
palette colour (`a == 0`) *erases* — it cuts a transparent hole in what was already
drawn (that is how the pac mouth is a wedge cut out of a disc). Later ops composite over
earlier ones.

### Primitives

All coordinates/sizes are normalized 0..1. `color`/`white`/`pupil` name a palette entry.

| Op | Fields | Draws |
|----|--------|-------|
| `disc` | `cx, cy, r, color` | a filled circle |
| `wedge` | `cx, cy, r, a0, a1, color` | a pie sector between angles `a0`..`a1` (degrees, from +x, clockwise; y is down). Use the erase colour for a mouth. |
| `dome` | `cx, cy, r, height, bumps, skirt, color` | a "dome + skirt" body (semicircular top, rectangular body, scalloped bottom of `bumps` tabs each dropping `skirt`) — a ghost silhouette |
| `eyes` | `cx, cy, spacing, r, pupil_r, look_x?, look_y?, white, pupil` | a pair of eyes `spacing` apart, pupils offset by `(look_x, look_y)` |
| `rect` | `x, y, w, h, color` | an axis-aligned rectangle (top-left `x,y`) |
| `rounded_rect` | `x, y, w, h, radius, color` | a rounded rectangle |
| `line` | `x0, y0, x1, y1, thickness, color` | a capsule stroke between two points |

### Animation clips

Each clip is `{ .name, .fps, .frames }`, where `.frames` lists frame indices (into
`.frames`) in play order. Ping-pong an animation by listing the indices out and back
(e.g. `.{ 0, 1, 2, 3, 2, 1 }`). Loop vs. once vs. ping-pong at runtime is the engine's
choice (`Sprite.loop`, ADR 0031); the clip itself is just an ordered index list + rate.

## MSF1 asset layout (provisional)

Little-endian, no compression (ADR 0031 §2; **provisional** pending the #109 interchange
codec — only the per-frame blob encoding would change behind the versioned header):

```
magic "MSF1" | version:u16 | width:u16 | height:u16 | frame_cnt:u16 | clip_cnt:u16 | reserved:u16
frames:  frame_cnt × (width*height*4) RGBA8 (straight alpha, row-major, top-to-bottom)
clips:   clip_cnt × { name_len:u8, name, fps:u16, n:u16, indices:n×u16 }
```

## Determinism

The rasterizer has no RNG and no time source; the same recipe always yields a
byte-identical sheet. This is pinned by tests (`raster.zig`, `recipe.zig`). Run them
with `mise run test` (the `spritegen` test target is part of the gate).
