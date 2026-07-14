# 0031. Sprite rendering: a cosmetic sprite/animation component, a dependency-free sheet asset, and a gpu texture path

- Status: accepted
- Date: 2026-07-13
- Amended: 2026-07-14 (Issue #122 — the null backend is now a real CPU texel sampler, addendum below)

## Context

Today every entity draws as a flat coloured quad. `Appearance` (ADR 0030) lets
content pick a colour, a world-space size, and a coarse silhouette (`rect`/`circle`),
but the North-Star games still look like coloured blocks: the Vulkan backend
rasterizes every quad as its bounding square (ADR 0030 addendum), and the headless
SVG (ADR 0029) draws a bare `<rect>`/`<ellipse>`. Pac-Man does not look like
Pac-Man — no chomp, no ghost silhouette, no animation.

Issue #105 (the spike this ADR records) moves the games to real **animated sprites**:
a sprite sheet of pre-rendered frames, a data-declared animation that names frame
ranges and a rate, and a textured-quad GPU path that samples the sheet. The spike's
job is to prove the path end-to-end for **pac only**, and to decide the shape of the
whole subsystem on paper so the follow-up lanes (#106 ghosts/frightened, #107 the
Snake retrofit) slot in without re-litigating the design. The image **interchange /
on-disk codec** is being researched separately in **#109** (QOI vs. a raw container
vs. …); this ADR must therefore pick a **provisional** in-repo asset format now and
record it as provisional, to be reconciled with #109's conclusion.

This subsystem touches the `gpu` port (a new texture surface) and adds a new
cosmetic component, so it gets an ADR (CLAUDE.md: "ADR for design decisions").

### Lanes (this ADR spans more than one PR)

The design here is whole; the implementation is phased:

- **Lane A (this PR, #105):** the genre-neutral procedural sprite **tool**
  (`tools/spritegen`), the provisional **asset format**, this ADR, and the committed
  **pac** recipe + generated sheet + viewable preview. **No `src/**` change, no GPU
  work.** This is the "prove we can author and see an animated pac, dependency-free"
  half.
- **Lane B (follow-up, #105):** the engine/GPU half — the `Sprite`/`Animation`
  component and its loader, the `gpu`-port texture API, the null-backend no-op, the
  Vulkan textured-quad pipeline behind `-Denable-vulkan`, and wiring `games/pacman`
  so pac renders as the animated sprite in `--play`.

## Decision

### 1. `Sprite` + `AnimationState`: cosmetic data, excluded from the state hash

Two new plain-data components (Lane B adds them to `src/engine/components.zig`,
threaded through the same call sites `Appearance` uses — `Bundle`, `scene.EntityDef`,
`prototype.Prototype`, `tilemap.Tile.bundle`):

```zig
/// A reference to a sprite sheet asset plus which clip to play. COSMETIC — no sim
/// system reads or writes it; excluded from the state hash.
pub const Sprite = struct {
    /// Package-relative path to the sheet asset (resolved at load, like `script`).
    sheet: []const u8,
    /// Name of the clip to play (must exist in the sheet); empty ⇒ frame 0, no play.
    clip: []const u8 = "",
    /// Playback behaviour when the clip ends.
    loop: LoopMode = .loop,
};

/// Live per-entity animation cursor. Advanced by a cosmetic render-time system from
/// wall-clock/frame time, NEVER from a sim tick — so it cannot enter the state hash.
pub const AnimationState = struct {
    time_s: f32 = 0, // seconds since the clip started
    frame: u16 = 0,  // resolved frame index into the sheet, for the renderer
};

pub const LoopMode = enum { loop, once, ping_pong };
```

The **frame grid, clip table, and fps live in the sheet asset** (below), not in the
component — the component only references a sheet and names a clip, so re-timing or
re-framing an animation is an asset edit, not a content edit (data over code,
CLAUDE.md). The clip's `fps` and `frames` list are read from the asset.

**Determinism (the load-bearing constraint).** Per the physics/VFX invariant —
"deterministic within the sim, or cosmetic and excluded from the state hash" — sprite
and animation state are **cosmetic and excluded from `World.stateHash`**, exactly as
`Appearance`/`Velocity`/`NavAgent` already are (ADR 0030). Concretely:

- `AnimationState` is advanced by a **render-time** system driven by real elapsed time
  (the `--play` loop's wall clock, ADR 0009 §4), *not* by `Sim.tick`. It is in the same
  category as present/FPS pacing: it never feeds collision, nav, or any simulated
  behavior.
- `stateHash` continues to hash only `transforms`/`healths`/`data`. Neither `Sprite`
  nor `AnimationState` is added to it. Lane B pins this with a `world.zig` test
  (attaching a `Sprite` must not perturb `stateHash`), mirroring ADR 0030's appearance
  test, and the `tests/determinism.zig` golden stays unchanged.
- Which animation is *playing* may be chosen by content/script (e.g. a future
  `on_hit` swapping a clip by writing `Sprite.clip`), but the **frame cursor** is pure
  cosmetics. A clip selection that must affect the sim would be a data component (ADR
  0024), not the animation cursor.

`Appearance` and `Sprite` coexist: an entity with a `Sprite` samples the sheet; one
with only `Appearance` keeps the flat-quad look. `Appearance.size` still sets the
quad's world footprint (the sprite is mapped onto that quad); `Appearance.color`
becomes a tint the textured pipeline multiplies (default white = untinted), which is
how Lane B can re-tint a frightened ghost blue (#106) without a second sheet.

### 2. The sprite-sheet asset: a provisional, dependency-free container (`.msf`)

The tool emits, and Lane B's engine decodes, a trivial in-repo container —
**MSF1** ("mana sprite format", version 1). It is deliberately the simplest thing that
carries frames + clips with **zero external dependency on either side** (encode in the
tool, decode in the engine), and it is explicitly **provisional**: #109 is researching
the interchange codec (QOI is the leading candidate for compressed RGBA), and MSF's
per-frame payload is defined so its pixel blob can later be swapped to a #109-blessed
encoding (QOI/RLE) behind the same header without touching the component or the GPU
path.

Layout (little-endian; no padding beyond the header word):

```
magic     : [4]u8  = "MSF1"
version   : u16    = 1
width     : u16               ; frame width in px
height    : u16               ; frame height in px
frame_cnt : u16
clip_cnt  : u16
reserved  : u16    = 0        ; header padding / future flags
frames    : frame_cnt × (width*height*4) bytes   ; RGBA8, straight alpha, row-major, top-to-bottom
clips     : clip_cnt × {
              name_len : u8, name : name_len bytes,
              fps      : u16,
              n        : u16, indices : n × u16    ; frame indices into `frames`
            }
```

Rationale for **raw straight-alpha RGBA8** as the provisional payload:

- **Trivially decodable in-repo** (Lane B needs ~20 lines: read the header, slice the
  frames, walk the clip table) — no codec to port, so the spike can't stall on one.
- **The existing `data.png` encoder already proves** the "dependency-free codec"
  pattern (uncompressed DEFLATE + CRC32); MSF is even simpler (no compression at all).
  When #109 lands, only the per-frame blob's encoding changes.
- **Straight alpha, not premultiplied**, is the conventional texture-upload form the
  Vulkan path (Lane B) wants; the tool rasterizes in premultiplied space internally
  (correct AA over transparency) and converts once on the way out.

The preview image (below) is a **separate** artifact from the asset — the asset is for
the engine, the preview is for a human.

**Sheets are DERIVED build artifacts, never committed (files-are-source-of-truth,
invariant #1).** An `.msf` sheet and its preview PNG are regenerable from a few lines
of committed ZON; checking them in would bloat git with binary blobs that are pure
functions of the recipe. The **recipe** (`.zon`) is the source of truth; the tool is a
*client* of it (invariant #1: "editors are optional clients of those files"). So MSF
is defined here as the **on-the-wire artifact shape** the tool produces and Lane B's
engine consumes at load/build time — not as a committed asset. Concretely:

- The tool writes the sheet + preview into a **gitignored** output dir
  (`**/sprites/generated/`), never into a committed tree.
- A `mise run assets` task (re)generates every committed recipe's sheet into that
  gitignored dir; this is exactly how Lane B's `--play`/engine obtains the sheet — from
  a build-time generate, not a committed binary (a `build.zig` generate step is the
  natural evolution once the engine consumes sheets, and stays genre-neutral by taking
  the recipe list as data, never hardcoding a game).
- The **determinism test** generates in-memory (no file) and asserts byte-stability;
  the committed golden is a *hash constant*, never a checked-in image.

### 3. A human-viewable preview (so the pac chomp is actually *seeable* today)

Lane A has no GPU, so "see the animated pac" cannot mean "run `--play`". The tool also
emits a **montage PNG** — every frame composited over a checkerboard (so transparency
reads) in a row — via the **existing** `data.png` encoder (uncompressed IDAT + CRC32,
already in-repo and dependency-free, ADR 0006). A human opens
`games/pacman/sprites/pac_preview.png` in any browser/OS image viewer and sees the
chomp frames side by side. This is the deliverable that makes the spike *visible*
without standing up Vulkan. Like the `.msf` sheet, the preview PNG is a **derived,
gitignored** artifact — produced by `mise run assets` (or a direct `mise run
spritegen` invocation), opened by the human, and never committed.

### 4. The `gpu`-port texture API (shape only; Lane B implements)

The port (ADR 0010) grows the minimal texture-sampling vocabulary a textured-quad
draw needs — nothing speculative (CLAUDE.md: pin only what the renderer uses). Plain
data, no Vulkan types above `gpu`:

- `TextureFormat` already has `rgba8_unorm`; `TextureUsage` gains `sampled: bool` (a
  texture read in a shader), alongside the existing `color_attachment`/`transfer_src`.
- `Device.createTexture(TextureDesc)` already exists (offscreen target); Lane B adds
  `Device.uploadTexture(tex, rgba_bytes)` (host → device copy) so a decoded sheet
  reaches the GPU, and `Texture.deinit(dev)` already frees it.
- A new **textured** scene pipeline variant: `createTexturedPipeline(format)` plus a
  `CommandList.bindTexture(tex)` and a `Vertex` with UVs (`u,v` added to the existing
  NDC-pos+RGB vertex, or a second vertex type — Lane B picks the smaller diff). The
  quad's UVs address the current frame's sub-rect of the sheet.
- **Null backend = a real adapter (the default).** `createTexture`/`uploadTexture`/
  `bindTexture` succeed and allocate/track host bytes, so every headless/CI build stays
  GPU-free and green and the null path remains the parity harness (ADR 0010 §3).
  *(**Superseded by the Issue #122 addendum below.** As first shipped, the null
  rasterizer kept drawing each quad's flat colour — "sampling real texels is the Vulkan
  path only" — but that made the textured sprite verifiable only by playing `--play` on
  a GPU box, so the null backend was made a real CPU nearest-neighbour texel sampler. The
  invariants this bullet protects — GPU-free, default, parity harness — all still hold.)*
- **Vulkan textured-quad pipeline behind `-Denable-vulkan`** (Lane B): a second
  pipeline whose fragment shader samples the bound sheet texture at the vertex UVs and
  multiplies by the `Appearance` tint. Authored in WGSL → committed SPIR-V (ADR 0006 /
  `src/gpu/CLAUDE.md`), like the existing scene shader.

The headless **SVG** emitter (ADR 0029) is unaffected — it cannot show a raster sprite;
it keeps drawing the `Appearance` silhouette, which stays the CI visual-regression net.

### 5. How a game references a sprite (content, not `src/`)

Entirely data (invariant #6). A prototype/scene-entity/tilemap cell adds a `.sprite`:

```zig
.sprite = .{ .sheet = "sprites/pac.msf", .clip = "chomp", .loop = .ping_pong },
```

The sheet path is package-relative (resolved at load like `manifest.script`). `pac`,
`ghost`, `snake segment`, `food` are **recipe files + generated sheets**, never engine
code. The tool that *produces* the sheet knows only generic primitives (§6).

### 6. The tool is genre-neutral (Lane A, built here)

`tools/spritegen` reads a ZON **sprite recipe** and deterministically rasterizes it to
an `.msf` sheet + a preview PNG. It knows only generic primitives — filled **disc**,
**wedge** (pie sector, for a mouth), **dome**+skirt (a ghost body), **eye pair**,
**rect**, **rounded-rect**, **line** — composed on a palette canvas, plus per-frame op
lists and named animation clips (frame lists + fps). "pac"/"ghost"/"snake"/"food" are
**recipes** (data under a game package), never hardcoded in the tool (invariant #6).
It adds no external dependency (it reuses `data.zon` to parse and `data.png` to
preview), is a lasting dev asset (future benches author sheets with it), and is run
cross-platform via `mise run spritegen -- <recipe.zon> <out-dir>`. See
`tools/spritegen/README.md` for the recipe grammar and the run/view commands.

The rasterizer is **deterministic** (same recipe → byte-identical `.msf`): no RNG, no
time, fixed-order supersampling, integer pixel loops. A determinism test pins it.

## Consequences

- **Pac finally animates** in `--play` (Lane B) and is *viewable today* (Lane A's
  preview PNG) — the concrete need #105 named.
- **Determinism is untouched:** sprites/animation are cosmetic and excluded from the
  state hash by policy, in the same category as `Appearance` (ADR 0030); the
  determinism golden does not move.
- **No new dependency:** the tool reuses `data.zon`/`data.png`; MSF and the montage are
  written in-repo. If #109 later blesses QOI, only MSF's per-frame blob encoding
  changes — the component, the clip table, and the GPU path are stable.
- **Nothing binary is committed:** the recipe (`.zon`) is the sole committed source of
  truth (invariant #1); sheets/previews are gitignored, regenerated by `mise run
  assets`. The determinism golden is a committed *hash constant*, not an image.
- **Provisional, by design:** MSF is a placeholder for #109's interchange decision and
  is recorded as such; the header versions it (`MSF1`) so a format bump is explicit.
- **The `gpu` port grows only a texture-sampling slice** (§4), justified by a concrete
  renderer need (a textured quad) and implemented by two backends (null no-op +
  Vulkan), per the abstraction policy — no speculative surface.
- **Deferred, named follow-ups:** ghosts + frightened re-tint via the `Appearance`
  tint (#106); the Snake segment/food retrofit (#107); reconciling MSF with #109's
  interchange codec; a script-side clip swap (`on_hit` → `Sprite.clip`) would need its
  own `mana`-surface ADR (ADR 0030's "no script touches Appearance" line applies
  equally to `Sprite`).

Cross-references: **#105** (this spike), **#106** (ghosts/frightened, follow-up),
**#107** (Snake retrofit, follow-up), **#109** (interchange-format research — MSF is
provisional pending its conclusion); builds on ADR 0029 (headless SVG), ADR 0030
(appearance as data), ADR 0010 (gpu port surface), ADR 0006 (Vulkan offscreen +
`data.png`).

## Addendum (Issue #122): the null backend samples the atlas on the CPU

Amended: 2026-07-14.

§4 above scoped the null backend as a real *no-op* adapter: it tracked uploaded texels
but its rasterizer kept drawing each sprite quad's flat tint, and "sampling real texels
is the **Vulkan** path only." In practice that made the textured-sprite output verifiable
**only** by playing `--play` on a Vulkan-capable box with a display — and sprite bugs (a
wrong animation frame, a mis-rotated facing, a flattened footprint) twice reached the user
because CI and the orchestrator could not *see* the pixels. That violates the LOOP first
principle that a game must never ship silently / deterministically broken: **headless
visual output is first-class**, not a Vulkan-only luxury.

**Reversal.** The null backend's textured pipeline is now a *real* CPU texel sampler
(`src/gpu/null/textured_raster.zig`, wired into `CommandList.drawTextured`).
`bindTexture` records the atlas the draw samples; `rasterTri` rasterizes the **same** two
triangles per sprite quad the Vulkan pipeline draws, barycentric-interpolates the UV
across the (possibly rotated) footprint, samples the atlas **nearest-neighbour**, tints
RGB and straight-alpha "over"-blends — mirroring `sprite.wgsl` + the Vulkan blend. Because
the null path consumes the exact `SpriteQuad`s `render.projectSprites` produces (same
projection, wedge-facing rotation, quad extents, UV sub-rects), a geometry/UV bug
reproduces headlessly, pixel-for-pixel modulo the shared-diagonal seam (a deterministic
test-double artifact; a top-left fill rule is unneeded).

This *strengthens* the null backend from a no-op into a faithful sampler while preserving
every invariant §4's bullet protected: still GPU-free (pure host math), still the default
headless/CI backend, still the parity harness (ADR 0010 §3), and still **cosmetic** —
excluded from the state hash (§1).

**New surface (all render-side, no new sim state):**

- `gpu.captureFrame` — an offscreen, sprite-aware render + readback that reuses the exact
  `renderFrame` recording the `--play` present loop uses, then reads the target back to
  RGBA8.
- `runtime --render-play-frame <out.png> [--ticks N]` — the headless mirror of `--play`'s
  pixels: it loads the scene, packs the atlas, advances **N deterministic fixed ticks**
  (fixed dt, not wall-clock, so the captured frame is reproducible), composites the flat
  quads + textured sprites through the null backend, and writes the PNG via the existing
  offscreen path (`data.png`). Needs **no GPU**; like the other headless modes a Lua-driven
  game still needs `-Denable-lua` for its scene handler to spawn the sprited entities.

Cross-reference: **#122** (this addendum). This does not change the `.msf` format, the
`Sprite`/`AnimationState` components, or the `gpu` port vocabulary — only the null
backend's implementation of `drawTextured` and two render-side helpers.
