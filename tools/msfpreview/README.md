# msfpreview — headless animated sprite-sheet previewer

A standalone dev tool (issue #129, phase 1) that makes an `.msf` sprite sheet
**inspectable by eye** without a window or GPU: it renders every clip's authored
**and mirror-inferred** facings, frames in phase order, into one filmstrip PNG.

This is phase 1 only. The interactive `zgui` editor (browse/scrub/play, hot-reload)
is a tracked follow-up (issue #129 phase 2) that needs the windowed tooling path —
not built here.

## Run (cross-platform)

Generate the sheet first (`mise run assets`), then preview it:

```
mise run msfpreview -- games/pacman/sprites/generated/pac.msf games/pacman/sprites/generated
```

Writes `<out-dir>/<stem>_filmstrip.png` (e.g. `pac_filmstrip.png`) — open it in any
browser / OS image viewer. Output is a **derived** artifact (never committed), same as
spritegen's own preview PNG.

## What you see

One row per **clip × facing**, columns in phase order, over a checkerboard (so
transparency reads — the same convention `tools/spritegen`'s montage uses):

- A **directional** clip (any of `up`/`down`/`left`/`right` authored, ADR 0033) always
  gets **four** rows, in that order. An authored facing renders as-authored; an absent
  horizontal facing (e.g. pac's `left`) renders its opposite's frames **X-flipped** —
  the exact "absence is the signal" mirror the engine applies at runtime, not a
  reimplementation of it.
- A **non-directional** clip (no facing authored) gets a single row: its base `frames`
  list.
- A sheet with **no clips at all** falls back to one row of every raw frame in sheet
  order, so it still previews something.

## Why this catches what a static montage can't

It reuses the exact runtime rendering path — `engine.sprite.resolveFacing` (the same
facing/mirror selection `render.projectSprites` calls) and `engine.gpu.captureFrame`
(the same CPU atlas-sampling rasterizer `--render-play-frame` uses) — so a facing,
mirror, or sampling bug shows up here exactly as it would in `--play`. This is the tool
that would have made #125's per-frame facing-flip obvious before it shipped.

## Not built here (deferred)

- **Tint/blink variants** depend on issue #128 (in flight). The seam: `layout.zig`'s
  grid is clip×facing; a variant dimension slots in as additional columns or a
  parallel canvas once #128 lands. Not scheduled by this tool.
- **The interactive editor** (issue #129 phase 2) — scrub/play, live hot-reload, `zgui`.
