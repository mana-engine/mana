# 0036. Text rendering: an embedded bitmap font + layout through the sprite atlas/batcher

- Status: proposed
- Date: 2026-07-14

## Context

mana has **no text rendering**. ADR 0034 (data-driven game UI) made this the
load-bearing first dependency of the whole UI subsystem — §6 is explicit that "no
glyph atlas, font loader, or text-layout path exists anywhere under `gpu` or
`engine` today" and that its Consequences **defer the font/glyph format decision to
issue #131 (this ADR)**. A HUD, menu, or inventory label — and independently, debug
overlays and the MSF viewer (#129) — cannot ship as colored rects; they need glyphs.

The forces, all pre-settled by existing invariants this ADR applies rather than
re-litigates:

- **Dependency-light / files-are-source-of-truth (CLAUDE.md invariants).** mana is
  deliberately dependency-free at its core; a TTF/OpenType stack (FreeType,
  stb_truetype, HarfBuzz) is a large, hinting-and-shaping-heavy dependency for a
  procedural engine whose sprites are already authored procedurally (`tools/spritegen`,
  ADR 0031).
- **"Vulkan never leaks upward" (invariant #4) + "reuse, don't build a parallel
  renderer."** Text is textured quads; the sprite subsystem (ADR 0031) already has a
  CPU-assembled RGBA atlas, a `gpu.SpriteQuad` batcher, a null-backend CPU texel
  rasterizer (ADR 0031 §4 addendum / #122), and a Vulkan textured pipeline. A second
  text-only renderer would duplicate all of it.
- **The physics/VFX determinism invariant** ("deterministic within the sim, or
  cosmetic and excluded from the state hash"): text is presentation, in the same
  category as `Appearance` (ADR 0030) and `Sprite`/`AnimationState` (ADR 0031).
- **Headless-testability** (ADR 0034 §2, ADR 0010 §3): glyph placement, advance
  widths, and line-break results must be assertable with the null backend, no window.

## Decision

### 1. The font is an embedded, dependency-free 5x7 bitmap (`src/engine/font5x7.zig`)

The glyph format is a **fixed-width 5x7 bitmap** covering the full printable ASCII
range (0x20 space .. 0x7E tilde, 95 glyphs), baked into source as a `[95][7]u8` table:
each glyph is 7 rows, each row's low 5 bits are its columns (`0b10000` = leftmost). A
set bit is an opaque ink texel; a clear bit is transparent. This is the same
"procedural asset baked in source, no external file" philosophy as `tools/spritegen`,
carried to type. **No font-file dependency is added** (no FreeType/stb_truetype/TTF
loader/HarfBuzz), so the default headless build rasterizes text with zero external
code — the DEP-FREE constraint #131 set.

Fixed-width (every glyph advances one identical cell) makes text layout pure integer
arithmetic and trivially deterministic, and it is exactly enough for a HUD, a debug
overlay, and the MSF viewer — the concrete needs on the table.

### 2. Glyphs draw through the EXISTING sprite atlas + quad batcher (no parallel renderer)

`text.buildFontAtlas` rasterizes each glyph to an RGBA8 frame (white ink, transparent
elsewhere) and packs them into a `sprite.Atlas` by **calling `sprite.buildAtlas`** —
the same atlas type and packing code sprites use. A glyph's UV sub-rect is
`atlas.uv("font", code - 0x20)`. `text.projectText` then turns a laid-out string into
`gpu.SpriteQuad`s — the same quad type `render.projectSprites` emits — so
`gpu.captureFrame`/`renderFrame` composite text through the identical batcher, null CPU
rasterizer, and (behind `-Denable-vulkan`) textured pipeline. **No new `gpu`-port
surface, no new pipeline, no new shader.** The white ink is multiplied by a per-draw
tint (reusing `SpriteQuad.tint`), so text can be any colour, exactly as a sprite is.

This keeps text on the `gpu`-port side (render/engine tier, importing `gpu`) and names
no Vulkan type — invariant #4 holds because it rides the sprite path that already does.

### 3. Layout: fixed-width advances + line breaking (`text.layout`)

`text.layout(gpa, text, opts)` produces the visible-glyph placements plus the block's
pen-advance width and total height. It handles: a fixed advance per cell; `'\n'` as a
hard line break; and — when `opts.max_width` is set — **greedy word wrapping** (a whole
word moves to the next line rather than splitting, unless the word alone exceeds the
line, which hard-breaks it at a cell boundary). Spaces and newlines advance the pen but
emit no glyph. It is pure and deterministic (no I/O, no RNG), so placement, advances,
and wrapping are all unit-asserted in-file.

### 4. Text is cosmetic and excluded from the state hash

`text.zig` reads **no sim state and writes no `World` column** — it takes a plain
`[]const u8` and returns placements/quads. There is no text ECS component and no
`Sim.tick` interaction, so — like `Appearance`/`Sprite` — text **cannot perturb
`World.stateHash`**, and the determinism golden (`tests/determinism.zig`) does not
move. (When #132's widget tree binds a live score to a label, that gameplay value is
already hashed sim state per ADR 0034 §4; the *rendering* of it stays cosmetic here.)

## Alternatives rejected

- **A TTF/OpenType stack (FreeType / stb_truetype / HarfBuzz).** Real vector fonts with
  hinting and shaping are the general answer, but they are a heavy dependency (or a
  large vendored C library) for a procedural, dependency-light engine that has no
  artist-authored font assets — the same reasoning ADR 0032 used to reject Aseprite/WebP
  for sprites. #131 explicitly forbids adding one; a bitmap font is the philosophy-fit
  choice. A future importer that bakes a TTF to a bitmap atlas at build time (mirroring
  ADR 0032's "Aseprite as a future *importer*, not the core format") would be its own
  ADR if artist-authored fonts ever become a concrete need.
- **A parallel text renderer / a new `gpu` glyph path.** Rejected by "reuse the sprite
  batcher, don't build a parallel renderer" and "no speculative flexibility": text is
  textured quads, and the sprite atlas + `SpriteQuad` + null/Vulkan batcher already draw
  those. A separate path would duplicate the rasterizer and double the surface to keep
  correct.
- **A signed-distance-field (SDF) glyph atlas.** SDF gives crisp scaling and is the
  modern choice for vector-quality text, but it needs a generator (another dependency or
  a nontrivial in-repo pass) and buys nothing for a pixel HUD/debug overlay at integer
  scale. Deferred until a game needs smoothly-scaled text.
- **Proportional (variable-width) metrics now.** Kerning/variable advances improve
  prose density but complicate layout and the bitmap table for no current need; the HUD
  and debug uses are fine fixed-width. A proportional advance table is an additive,
  non-breaking future change (a per-glyph width array) if a game needs it.
- **A `text` ECS component drawn by a per-entity sim system.** Would risk text becoming
  sim state / entering the hash and contradicts ADR 0034's "UI is a port-tier, cosmetic,
  one-way-bound concern." Text here is a pure render-side function, not a component.

## Consequences

- **The UI subsystem's prerequisite is unblocked** (ADR 0034 §8): #132 (widget/layout
  ZON) and #133 (Pac-Man HUD) can render real labels, and debug overlays / the MSF
  viewer (#129) get text for free.
- **No new dependency** and **no new `gpu`-port surface**: text reuses the sprite atlas,
  `SpriteQuad`, and both backends' existing draw paths; the Vulkan side needs no new
  shader or pipeline.
- **Headlessly verifiable**: layout (advances, `'\n'`, word-wrap, hard-break), the atlas
  (a region per glyph; blank space vs. inked letter), and end-to-end rendering (a glyph
  composites ink through the null backend; a tint colours it) are all asserted without a
  window — matching the null-backend-is-a-real-adapter discipline.
- **Determinism untouched**: text reads/writes no sim state and adds no component, so
  `World.stateHash` and the determinism golden are unchanged.
- **Committed to:** a fixed-width 5x7 embedded bitmap for printable ASCII; glyphs as
  frames in a `sprite.Atlas`; text as `gpu.SpriteQuad`s through the existing batcher;
  text cosmetic and hash-excluded.
- **Explicitly not doing / deferred follow-ups:** vector/TTF fonts, an SDF atlas,
  proportional/kerned metrics, non-ASCII/Unicode, right-to-left, and a
  `runtime`-level text-render CLI mode — each its own future issue (and ADR where it is a
  real design decision) when a game names the need. This ADR ships the smallest real
  vertical slice: atlas + layout + null-backend raster + tests.

Cross-references: **#131** (this issue), ADR 0034 (game-UI direction — deferred this
decision here; §6 prerequisite, §2 headless-testability), ADR 0031 (sprite rendering —
the atlas + `SpriteQuad` batcher + null CPU rasterizer reused; the cosmetic/hash-excluded
precedent), ADR 0032 (sprite-format survey — the "no heavy dependency, importer is a
future ADR" reasoning applied to fonts), ADR 0030 (appearance-as-data cosmetic exclusion),
ADR 0010 (gpu port surface — reused unchanged), #129 (MSF viewer, an independent consumer),
#62 (HUD need).
