# 0029. Headless SVG render output: a GPU-free way to *see* a level

- Status: accepted
- Date: 2026-07-13

## Context

`src/engine/render.zig` already has a pure, GPU-free, deterministic half of
rendering: `project(gpa, world, view, palette)` turns a `World`'s entity transforms
into NDC-space `gpu.Quad`s through a configurable camera (ADR 0014 — top-down
orthographic by default, isometric opt-in). Only the *rasterizing* half
(`--render`, ADR 0006) needs a GPU, and it is gated behind `-Denable-vulkan` — a
default build cannot produce any visual artifact at all.

Pac-Man (`games/pacman`) is the first game with real level design (a hand-authored
maze, ghost start cells, scatter corners). There is currently no way to *see* a
level short of building with `-Denable-vulkan` (deferred, needs a GPU + shader
toolchain) or reading the raw ZON grid by eye. Two concrete needs:

1. A human wants to look at a level (or a package's whole layout) without standing
   up Vulkan/SDL3.
2. CI wants a **visual regression net** distinct from the state-hash determinism
   golden (`tests/determinism.zig`) — that hash catches *simulation* drift, not
   *layout* drift (e.g. a maze row typo that still hashes fine because collision
   math is unaffected, or a projection/scale change that silently shifts everything
   on screen).

## Decision

### 1. An engine SVG emitter: `quads → SVG`, no GPU, no new dependency

Add `src/engine/render_svg.zig`: a pure function `toSvg(gpa, quads, view,
background) -> []u8` that emits a text SVG document from `render.project`'s output —
a full-bleed background rect, then one `<rect>` per quad, in the caller's given
order. It does not call `project` itself and does not touch `World` — it only knows
the `gpu.Quad` vocabulary already shared with the Vulkan backend, so this is a
second, alternative consumer of the same pure projection stage, not a parallel
render pipeline.

SVG is plain text: this needs **zero new dependencies** (no rasterizer, no image
codec) and compiles unconditionally into `engine` — never behind `-Denable-vulkan`.

### 2. Two new runner modes, both genre-neutral

- `mana <pkg> --render-svg <out.svg>`: load the entry scene (the same load path as
  `--render`/`runOnce` — manifest → scene, no ticking, no script), project it, emit
  SVG, write the file. Works on the **default** build.
- `mana <pkg> --filmstrip <out-dir> [--ticks N]`: build a full `Sim` (standard
  system set, package script, prototypes — the same load path as `runOnce`), run
  `N` fixed ticks (default 60), writing one SVG per tick (`frame_0000.svg …`) to
  `out-dir`. This is a headless scrub tool: a human can flip through frames and
  watch ghosts nav-move, pickups get eaten, and pac respawn, entirely offscreen.

Both modes draw whatever `render.project` hands them — generic quads at generic
positions/colours. Neither mode, nor the emitter, has any concept of a maze, a
ghost, or a dot (invariant #6): `render_svg.zig` takes `[]const gpu.Quad`, the same
shape the Vulkan backend consumes, and the runner changes are argument parsing plus
calling the existing engine + scene-loading pieces.

Driving a specific playthrough (e.g. "turn left at tick 40, verify pac eats the
dot") via a recorded input trace is deliberately **out of scope** here — that is
the concern of the scenario-test harness (ADR 0028, in flight in a parallel lane).
`--filmstrip` only free-runs the sim; pairing it with a trace format is future work
once ADR 0028 lands.

### 3. Why SVG over a CPU-rasterized PNG

A software rasterizer in the null gpu backend was the other option (draw quads to
an RGBA buffer, encode via the existing `data.png` encoder). Rejected for now:
- **Heavier**: needs real rasterization (fill rules, at minimum AA-free box fill),
  which is more code than a text emitter for the same information content.
- **Not diffable**: a PNG regression shows as "bytes differ"; an SVG regression
  shows as a **readable text diff** (a rect's `x`/`y`/`fill` changed), which is far
  more useful in a PR review or CI log.
- **Human-viewable everywhere**: any browser renders SVG directly — no local image
  viewer needed to eyeball a level.

CPU-rasterized PNG remains a reasonable future addition (e.g. for a thumbnail
gallery) but is deferred until a concrete need names it.

### 4. Why not the live SDL3+Vulkan window

Already deferred by ADR 0006/0009/0012/0013. Interactive play is a different need
(feel, timing, input) than "let me see this level" or "catch a layout regression in
CI" — this ADR does not touch that path.

### 5. Genre-neutrality

The emitter and both runner modes operate purely on `render.View`/`gpu.Quad` —
the same vocabulary `runRender`/`playLoop` already use. No maze/pac/ghost concept
appears in `src/engine` or `src/runtime`; a Snake board and a Pac-Man maze go
through the identical code path.

### 6. Determinism: byte-stable SVG

`toSvg` is pure and total: every coordinate and colour channel is printed at a
fixed 2-decimal-place precision, and quads are emitted in the exact slice order the
caller passes in — `render.project`'s already-documented far-to-near depth-sorted,
index-tie-broken order (ADR 0014's painter's-algorithm sort). No hash-map or set
iteration touches the output. Two calls with the same inputs are byte-identical,
which is what makes the checked-in goldens (below) meaningful diffs rather than
flaky noise.

### 7. Render-golden tests: the visual regression net

New, **additive** golden tests render a fixed scene straight to SVG (bypassing the
manifest/script-API gate — they load the `.zon` scene file directly, so they need
no `-Denable-lua` build) and assert byte-equality against a checked-in fixture
under `tests/fixtures/`, created via the existing `MANA_UPDATE_GOLDENS=1` escape
hatch (the pre-commit/Claude hook blocks casual edits there). One golden for the
Pac-Man maze, one for the Snake board. This is a **second, independent** golden
alongside `tests/determinism.zig`'s state-hash golden
(`0x65f2a1949cd9fc40`, untouched by this ADR) — the hash catches simulation
(behavioural) drift, the SVG catches layout (visual) drift. Neither subsumes the
other.

## Consequences

- A level (or any scene) is visible without a GPU, a window, or the Vulkan/SDL3
  toolchain — unblocks Pac-Man level-design iteration immediately.
- CI gets a text-diffable visual-regression net that runs on the default build,
  distinct from and complementary to the determinism hash.
- No new dependency, no new build flag: `render_svg.zig` is plain `std` + the
  existing `gpu.Quad`/`render.View` types.
- **Deferred, named follow-ups**: a CPU-rasterized PNG path in the null gpu
  backend; wiring `--filmstrip` to a recorded input trace once ADR 0028 (scenario
  harness) lands; per-entity sprite shapes in the emitter (today every quad is a
  rect — a circle variant for round entities is a straightforward additive follow-
  up, not required for the initial visual-regression net).
