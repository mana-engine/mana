# 0032. Animated-sprite interchange: no existing format fits — evolve MSF, don't replace it

- Status: accepted
- Date: 2026-07-14

## Context

ADR 0031 (#105) shipped `Sprite`/`AnimationState` and a **provisional** dependency-free
sheet container, MSF1 (`src/data/msf.zig`): a versioned header, raw straight-alpha
RGBA8 frames on a uniform grid, and a clip table (name, fps, frame-index list). It was
explicitly recorded as provisional pending this issue (#109): a deliberate, honest
survey of whether a good **interchangeable** (portable, tool-agnostic) animated-sprite
format already exists, so mana isn't reinventing something that's genuinely fine.

The bar, drawn from a data-driven engine's real needs and CLAUDE.md's invariants
(files-are-source-of-truth, dependency-light, human-diffable data): lossless RGBA,
per-frame timing, named clips/tags, pivot/anchor + optional hitbox metadata,
atlas/packing, palette support, mmap/stream-friendliness, dependency-light decode
(ideally in-repo, no new external dep), and human-diffable/round-trippable.

## Survey

| Format | Lossless RGBA | Per-frame timing | Named clips | Anchor / hitbox | Atlas/packing | Palette | Stream-friendly | Decode dependency | Diffable |
|---|---|---|---|---|---|---|---|---|---|
| APNG | yes (deflate) | yes | no | no | no | optional (PLTE) | no (compressed) | medium — full inflate + acTL/fcTL/fdAT chunks | no (binary) |
| GIF | **no** (1-bit alpha) | yes | no | no | no | yes (≤256, mandatory) | medium (LZW) | low, but moot | no |
| WebP (anim, lossless) | yes | yes | no | no | no | no | no (VP8L blocks) | **heavy** — bespoke entropy coder, no Zig std support | no |
| Aseprite `.ase`/`.aseprite` | yes | yes | **yes (tags)** | **yes (slices: pivot+rect)** | partial (cels/layers) | yes (indexed) | no (zlib cels) | **heavy** — evolving multi-chunk vendor binary + zlib | no |
| TexturePacker/spritesheet PNG+JSON | yes (PNG) | usually | often | sometimes (pivot; rarely hitbox) | **yes, natively** | no | depends | light in principle, but **no single schema exists** | yes (JSON text + PNG) |
| Godot SpriteFrames (`.tres`) | n/a (refs textures) | yes | yes | no | no | no | n/a | heavy — Godot resource/object model | nominal (engine-internal) |
| Unity sprite meta + AnimationClip | n/a | yes (curves) | sort of | pivot only | yes (SpriteAtlas) | no | n/a | heavy — Unity YAML object model + Mecanim | nominal (GUID/fileID churn) |
| Lottie | n/a (**vector**) | yes | yes (markers) | n/a | n/a | n/a | n/a | heavy (vector rasterizer/player) | yes, wrong level |
| Rive | n/a (vector + state machine) | yes | yes | n/a | n/a | n/a | n/a | **heaviest** — proprietary runtime/renderer, binary | no |
| Spine JSON | n/a (skeletal/attachments) | yes | yes (skins/anims) | bone-space, not sprite anchor | n/a | n/a | n/a | heavy — licensed Spine runtime/editor | yes, wrong level |
| QOI | yes (this is its whole point) | **no animation concept at all** | no | no | no | no | yes (linear stream) | **light** (~300-line decoder) | no |

**Raster-timeline formats (APNG, GIF, animated WebP).** All three carry pixels + a
frame sequence and nothing else: no clip names, no anchor, no atlas. GIF fails the
hard requirement outright — 1-bit transparency can't hold spritegen's anti-aliased
edges losslessly. APNG is functionally closest of the three (true lossless RGBA,
per-frame delay/dispose/blend) but real-world tooling support is inconsistent (many
image libraries silently ignore `acTL`/treat it as a static PNG) and it still has zero
clip/anchor vocabulary — any engine consuming it needs a bespoke sidecar anyway. WebP's
lossless mode (VP8L) is a genuinely heavy dependency: a bespoke entropy coder with no
equivalent in Zig's standard library (unlike PNG's deflate, which `std.compress.flate`
already gives us for free) — adopting it would mean either vendoring libwebp or
reimplementing a nontrivial spec for a format that still lacks every metadata need.

**Authoring-tool formats (Aseprite, TexturePacker-family, Godot, Unity).** Aseprite's
`.aseprite` is the strongest **functional** fit on the whole table — tags are literally
named clips with playback direction, and slices carry a pivot point and hitbox-shaped
rectangles per frame, which is exactly what #109 asks for. But it is a single vendor's
evolving binary chunk format (old/new palette chunks, cel chunks with per-cel zlib,
tags/slices/user-data/tileset chunks, version-dependent quirks) — decoding it
in-repo means committing to track a proprietary spec we don't own, for content mana
doesn't currently have (spritegen is procedural; no artist is authoring `.aseprite`
files in this repo). That's a real, ongoing dependency-weight cost even with zero
external library, and it is the standard reason real engines integrate Aseprite via
its **CLI export to PNG+JSON**, not by parsing `.aseprite` directly — which folds this
candidate into the next one. Godot's `SpriteFrames` and Unity's sprite
meta/`AnimationClip` are both disqualified on category: they are serializations of
each engine's own internal resource/object graph (GUIDs, `fileID`s, Mecanim state
machines), not portable interchange formats — they don't even claim to be. TexturePacker
/ "spritesheet-PNG+JSON" is the closest **philosophical** fit (an atlas PNG — lossless,
already an in-repo dependency-free codec, `src/data/png.zig` — plus a text metadata
sidecar, which is exactly mana's own PNG+ZON pattern) but there is no *one* schema:
TexturePacker alone ships ~6 mutually incompatible JSON dialects, Aseprite's own JSON
export is a seventh, and Godot/Unity read none of them. "Adopt spritesheet+JSON" is not
actually adopting anything — it's committing to design our own schema, which is this
ADR's job either way.

**Vector/skeletal formats (Lottie, Rive, Spine).** All three are a category mismatch:
mana's animations are pre-rendered whole-frame raster sequences (spritegen rasterizes
procedural recipes deterministically), not vector keyframes or bone/attachment
deformation. Forcing raster frames through any of them means embedding raster assets
inside a vector/skeletal wrapper and pulling in a full player/runtime (a real vector
rasterizer for Lottie, Rive's proprietary compiled-graph runtime, Spine's licensed SDK)
to get the same pixels back out that a plain sheet already gives directly. Rejected on
representational mismatch, not a close call.

**QOI.** Confirmed still-image-only, exactly as the issue flags: no frame sequence,
no timing, no clip concept in the spec at all. Its decoder genuinely is tiny and
dependency-free (~300 lines, portable to Zig trivially) — it is a strong candidate for
the **per-frame pixel codec** inside a container (as ADR 0031 already anticipated), not
a container by itself. Nothing here changes that plan.

## Decision

**The reasons the existing options fall short hold up.** No surveyed format is
simultaneously lossless, named-clip-aware, anchor/hitbox-capable, dependency-light to
decode, and diffable. The closest functional fit (Aseprite) is tool-locked and
decode-heavy for content we don't have; the closest philosophical fit
(spritesheet+JSON) isn't a real single schema. Adopting either would mean writing a
comparable amount of new parsing code anyway, for a worse fit than what's already
started.

### 1. Evolve MSF — do not supersede it, do not adopt an external format

MSF1 already gets the hard parts right for this survey's bar: lossless RGBA8, named
clips, a single dependency-free codec shared symmetrically by the encoder
(`tools/spritegen`) and the decoder (the engine), a versioned header, and a
determinism-pinned round-trip test. Per ADR 0031's own framing, only the *frame-blob
encoding* was ever meant to be provisional. This ADR concludes the container shape
itself was sound; it evolves to **MSF2** rather than being replaced:

- **Per-frame duration override** (optional; absent ⇒ falls back to the clip's `fps`).
  This is the one concrete, low-cost gap versus every raster-timeline and
  authoring-tool format surveyed (APNG/GIF/WebP/Aseprite all support holding an
  individual frame — e.g. an anticipation frame — longer than its neighbors).
- **A per-sheet anchor point** (informational metadata, carried through so an
  interchange round-trip never silently drops it). Recorded, but **not yet wired to
  any consumer** — Lane B (ADR 0031 §1) currently maps the whole sheet onto
  `Appearance.size`'s quad with no separate anchor concept, so adding a *consumed*
  anchor now would be exactly the speculative flexibility CLAUDE.md rules out. It
  becomes load-bearing the day a game needs off-center compositing; until then it's
  metadata that survives round-tripping, not new engine behavior.
- **No hitbox field, no palette mode, in MSF2.** Aseprite's slices prove hitbox
  metadata is a normal thing for a format like this to carry, and it would be cheap to
  add — but mana already has an independent, content-declared collider model (ADR
  0025) with zero current use for a sprite-frame-derived hitbox, and no game exercises
  palette-constrained color. Adding either now fails "no speculative flexibility /
  second concrete impl planned, or don't abstract." Deferred, explicitly, not
  forgotten — the versioned header makes a future MSF-bump for either a clean,
  non-breaking addition when a real game need names it.
- **Frame grid stays uniform** (no per-frame rects) — this is spritegen's own native
  output shape and keeps the format trivially mmap/stream-friendly (fixed stride, no
  offset table needed). A future importer converting a *packed, non-uniform* external
  atlas into MSF pads to a common cel size at import time — a well-understood
  "un-packing" step — rather than mana's own container growing variable-length frames.

### 2. Formalize the PNG+ZON pair as the actual interchange escape hatch

The one genuine gap MSF1 has as an *interchange* vehicle — as opposed to an engine
runtime asset — is that nothing outside mana can produce or consume it. Rather than
inventing a JSON dialect (mana already standardized on ZON as its data format;
introducing JSON purely to match other tools' convention would itself be a new format
for zero benefit), this ADR specifies the interchange pair as **an atlas PNG (via the
existing dependency-free `src/data/png.zig`) plus a ZON sidecar** shaped like MSF's own
header/clip table (width/height, frame count, clip name/fps/frame-list, MSF2's
per-frame duration override and anchor). ADR 0031 §3's montage preview PNG is the seed
of this — today it's a human-viewing artifact only; making it byte-accurate and
round-trippable (a fixed per-frame layout the sidecar's rects describe) turns it into
the real import/export surface, without adding a dependency on either side (still
`data.png` + `data.zon`, both already in-repo). This is follow-up implementation work,
not part of this ADR.

### 3. QOI's role is unchanged

The survey validates, rather than revisits, ADR 0031's plan: QOI (or an equivalent
tiny RLE scheme) remains the leading candidate for MSF's per-frame pixel encoding
(a future "MSF3"), swapped in behind the same versioned header without touching the
component or GPU path. This ADR does not schedule that work; it only confirms QOI was
never a candidate to replace the container.

## Consequences

- **MSF is no longer provisional in shape** — its container design (header, clip
  table, dependency-free codec shared by encoder and decoder) is the accepted answer
  to #109; only its frame-blob compression remains open (QOI/MSF3, unscheduled).
- **No new dependency, on either side** — MSF2 and the PNG+ZON interchange pair both
  stay inside `data.png`/`data.zon`/`data.msf`, exactly the pattern ADR 0031 set.
- **Concrete follow-up work** (separate PRs, not this ADR): bump `src/data/msf.zig` to
  MSF2 (per-frame duration override + anchor field, additive to the header so MSF1
  files stay readable or are cleanly versioned-out); make the spritegen preview
  byte-accurate/round-trippable and pair it with a ZON sidecar; write the MSF⇄PNG+ZON
  converter. None of this is done in this lane (research/ADR only, per scope).
- **Explicitly not doing:** adopting Aseprite, TexturePacker-JSON-as-is, GIF, APNG,
  WebP, Godot/Unity resources, Lottie, Rive, or Spine as mana's sprite container;
  adding hitbox or palette-mode fields until a real game exercises them.
- **Aseprite stays a plausible future *importer* target** (not the core format) if
  mana ever wants artist-authored content alongside spritegen's procedural recipes —
  worth its own ADR if that need becomes concrete.

Cross-references: **#109** (this issue), ADR 0031 (MSF1, provisional — reconciled
here), **#105/#106/#107** (sprite spike + follow-ups that consume this decision).
