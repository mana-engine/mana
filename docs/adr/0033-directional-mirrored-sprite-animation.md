# 0033. Directional + mirrored sprite animation: facing-selected clips replace wedge rotation

- Status: proposed
- Date: 2026-07-14

## Context

ADR 0031 shipped cosmetic `Sprite`/`AnimationState` components, the dependency-free
MSF sheet container (ADR 0032 accepted its shape), and a textured-quad path that both
backends rasterize. To make Pac-Man *face* its travel direction, that lane took a
shortcut: `render.projectSprites` computed the screen-space angle of an entity's
`Velocity` and stored it on `SpriteQuad.angle`, and the gpu vertex builder rotated the
textured quad by that angle. One radially-symmetric wedge frame was spun to point where
the entity moved.

Two problems follow from rotating one frame:

1. **It flips per frame at intersections (#125).** At a grid intersection Pac's
   `Velocity` is momentarily zero for a tick or two while nav re-targets. Zero velocity
   resets `angle` to 0 (the default right-facing pose), so Pac snaps to face right for a
   frame and then back — a visible flicker. The facing is recomputed from scratch every
   frame with no memory.
2. **It does not generalize.** Rotating a pre-rendered frame only works for a
   radially-symmetric silhouette (a disc with a mouth). A ghost, a fish, a knight — any
   character whose art is not symmetric under rotation — looks wrong when spun: its "up"
   pose is not its "right" pose rotated 90°. Rotating raster sprites is simply not how
   sprite characters are drawn; the industry-standard answer is a **directional sheet**
   — distinct pre-rendered frames per facing — with horizontal mirroring to halve the
   authored art for left/right-symmetric characters.

This is a cosmetic, render-side concern (the physics/VFX invariant: sprites are
"cosmetic and excluded from the state hash", ADR 0031 §1). It realizes/extends ADR
0031/0032; it does not touch the sim or the determinism hash.

## Decision

### 1. A clip gains a facing dimension; a frame is `clip[facing][phase]`

MSF's `Clip` keeps its non-directional frame list (the `frames` field — the
**single-facing fallback**, unchanged for non-directional sprites) and gains an optional
per-facing set: `up`, `down`, `left`, `right`, each an independent phase list into the
same sheet frames. A directional entity's rendered frame is
`clip.facing[latched_facing][phase]`; a non-directional entity ignores facing entirely
and animates `frames` exactly as before. This is additive: a clip that authors no facing
is byte-for-byte the old behavior.

Facing is a **screen-space** concept (up/down/left/right on the display), so the enum
lives with the format (`data.msf.Facing`) but the engine classifies an entity's
*world-space* travel heading into it through the active projection (below), keeping the
selection projection-correct rather than assuming world axes equal screen axes.

The MSF container versions to **MSF2** (magic `"MSF2"`, `version = 2`): the per-clip
wire layout now carries a base list, then a one-byte facing mask, then a list per
present facing. Sheets are gitignored derived artifacts (ADR 0031 §2), so no committed
asset breaks; the encoder (`tools/spritegen`) and decoder (`src/data/msf.zig`) move
together and the round-trip property test (`parse(serialize(x)) == x`) pins both
directions in lockstep, extended to cover directional clips. ADR 0032's *proposed*
per-frame-duration and anchor additions remain unimplemented; when a real game needs
them they layer onto this versioned header additively (a future bump), exactly as ADR
0032 anticipated — this ADR realizes the container's first evolution, it does not
foreclose that one.

### 2. Mirror rule: absence is the signal (declared, decided)

For a horizontally symmetric character (Pac, most top-down actors) authoring both the
left and right sheets is redundant. The rule, with **no boolean flag**:

- **Exactly one** horizontal facing authored (`left` xor `right`): the **opposite** is
  rendered by X-flipping the authored one's UVs. Declaring one facing *is* the request
  to mirror.
- **Both** authored: each is used **as-authored**, no auto-flip — the escape hatch for a
  character that is not horizontally symmetric (a face in profile, an asymmetric tool).
  Voluntary declaration overrides inference.
- **Neither** authored (a purely up/down or non-directional clip): fall back to the base
  `frames` list, no mirror.

Absence carries the intent, so the format needs no per-clip "mirror me" boolean that
could disagree with the frames present. The flip is a **UV swap at emission**
(`render.projectSprites` swaps the quad's `uv_min.u`/`uv_max.u`), interpolated linearly
by the exact same vertex builder and sampled by both backends — **no shader change, no
recompile**. Vertical facings are never auto-derived (you cannot X-flip "up" into
"down"); a missing vertical facing falls back to `frames`.

### 3. Latch the heading; retire the wedge rotation

The engine latches an entity's last **non-zero** travel heading on its (cosmetic,
hash-excluded) `AnimationState`: the render-time `sprite.advance` writes
`AnimationState.heading` from the entity's `Velocity` whenever it is non-zero and leaves
it untouched when velocity is zero. `render.projectSprites` classifies that latched
heading through the projection into a `Facing` and selects `clip[facing][phase]`. Because
the heading persists across the brief zero-velocity ticks at an intersection, the facing
no longer flickers (#125 fixed) — this latch alone is the fix.

The `SpriteQuad.angle` field and the gpu vertex builder's rotation are **deleted**: a
directional sheet + mirror is the whole facing mechanism now, and rotating a
pre-rendered frame was always the wrong tool (§Context). Sprite quads are axis-aligned
again, so the non-square-viewport squash the rotation guarded against (#121) cannot
occur by construction.

### 4. Tool + content

`tools/spritegen` clips gain the same optional `up`/`down`/`left`/`right` phase lists;
a clip that authors any facing derives its base list from the first present facing (in
order right, down, up, left) so a never-moved entity has a sensible default pose. The
`games/pacman` pac recipe authors up, down, and right chomp frames (left auto-mirrored
from right) so Pac chomps while facing all four travel directions. "pac" stays content
(invariant #6); the tool learns only the generic facing vocabulary.

## Consequences

- **The intersection flip is gone** and facing generalizes to any character: ghosts
  (#106) and future actors author a directional sheet and get correct facing for free,
  with left/right mirroring halving the art when symmetric.
- **No shader recompile, no new dependency, no GPU needed to verify:** the mirror is a
  CPU-side UV swap; the null backend's headless `--render-play-frame` capture shows Pac
  facing all four directions and proves the flip is gone, so a facing regression is
  caught in CI, not by a user playing `--play` (the ADR 0031 §122 addendum principle).
- **Determinism is untouched:** `AnimationState.heading` is cosmetic and hash-excluded
  like the rest of the animation cursor (it is written from `Velocity` by the wall-clock
  render-time system, never a sim tick); the pinned `tests/determinism.zig` hash does not
  move, and the "a sprite does not perturb the state hash" world test still holds.
- **MSF is now MSF2.** MSF1 files no longer decode (magic changed) — acceptable because
  sheets are regenerated derived artifacts, never committed (invariant #1). The
  round-trip test and `tools/spritegen` move in lockstep.
- **Committed to:** a facing dimension in the sheet format and the absence-is-the-signal
  mirror rule. **Not doing:** per-frame duration / anchor (ADR 0032, unscheduled);
  vertical mirroring; runtime tint/blink cues (a separate phase-2 issue); any sprite
  rotation.

Cross-references: **#127** (this phase), supersedes the bug-framed **#125**; realizes/
extends ADR **0031** (sprite rendering) and ADR **0032** (MSF container); sets up ADR
0031's named follow-ups #106 (directional ghosts) and #107 (Snake).
