# 0038. Game package layout: modular, grouped content over monolithic blobs

- Status: proposed
- Date: 2026-07-15

## Context

A game is "a dir of ZON + Lua + node graphs + assets with a `game.zon` manifest"
(invariant #5), and the engine has zero knowledge of any specific game. That
contract says nothing about *how the files inside a package are organised* — and the
two real games we have are already outgrowing the flat, one-file-per-kind shape they
started with:

- `games/pacman/` is one `rules.lua` (303 lines — grid math, four ghost AIs, mode
  timing, input, HUD flashing, all in one file) plus one `prototypes.zon` (188 lines:
  pac + four ghosts) plus `hud.zon`, `scenes/maze.zon`, `sprites/`, `scenarios/`.
- `games/snake/` is the same shape at smaller scale (`rules.lua` 153, `prototypes.zon`
  40).

Both files are single blobs the loader reads by an explicit manifest-named path. This
is fine at 40 lines and painful at 300: a change to ghost targeting and a change to the
input path collide in the same file and the same review diff, and a prototype tweak
re-parses/re-diffs all five archetypes at once. As more North-Star games land, "one
`rules.lua`, one `prototypes.zon`" does not scale.

The convention has also **already diverged**, aspirationally, without a decision:

- `games/pacman` + `games/snake` keep `rules.lua`/`prototypes.zon` at the package root.
- `games/chronicle` + `games/sandbox` ship an **empty `scripts/` directory** (a
  `.gitkeep`) and an empty `assets/` — scaffolding for a multi-file layout that no
  loader or game actually uses yet.

No canonical answer exists, so this ADR sets one before either divergence hardens into
two incompatible conventions.

### What the loader does today (the constraint this ADR must fit)

Loading is **100% manifest-driven, single-file, explicit-path** — there is no
directory globbing of content anywhere in `src/`:

- `src/runtime/manifest.zig` — `Manifest` is `name`, `version`, `entry_scene`,
  `scenes: []const []const u8`, optional `prototypes: ?[]const u8`, `script:
  ?[]const u8`, `hud: ?[]const u8`, `script_api`, `projection`, `native_module`. Every
  content path is a package-relative string the author writes out.
- `src/runtime/main.zig` — `loadPrototypes`/`loadPackageScript`/`loadHud` each do
  `manifest.<field> orelse return`, `std.fs.path.join(pkg, rel)`, one
  `readFileAllocOptions`, one pure `parse`. `prototypes.zon` parses to
  `engine.prototype.File{ prototypes: []const Prototype }` (a `.{ .prototypes = .{…} }`
  wrapper) assigned into `Sim`. Sprite sheets are pulled in *by reference* from
  scene/prototype data (`sprite.sheet` strings), never by scanning `sprites/`.
- `manifest.watchPaths` builds the hot-reload set (ADR 0005) by **enumerating the
  manifest's explicit paths** — `game.zon` + every `scenes[]` entry + the optional
  `prototypes`/`script`/`hud` — not by walking the filesystem.
- Parsing is `data.parseLenient`, which **ignores unknown manifest fields**, so an
  older runner tolerates a newer `game.zon` (relevant to migration, below).
- **Lua is flat single files.** ADR 0003 §7 removed `package`/`require` from the
  sandbox entirely; §Deferred records "VFS-scoped `require` for multi-file script
  packages — its own ADR when needed." That need is now here.

There is thus **no existing globbing precedent to cite** and **no working multi-file
convention** — this ADR gets to define both cleanly.

### Forces (invariants this ADR applies, not re-litigates)

- **Files are the source of truth; editors are optional clients** (invariant #1) and
  **prefer data over Lua** — the layout must keep every artifact a human-editable,
  diffable file, and must not push structure into code.
- **The engine is genre-agnostic** (invariants #5/#6): the loader may know *kinds of
  artifact* and a *directory convention*, but never a game or a feature name.
- **Per-file hot reload is first-class** (invariant #2, ADR 0005): splitting a blob
  into files should make reload *finer*, never coarser.
- **Determinism** (ADR 0004 §8): load order feeds registration order feeds the state
  hash. Directory iteration order is **not** OS-guaranteed, so any globbing must impose
  a deterministic sort — the single most important constraint here.
- **No speculative flexibility** (CLAUDE.md): pick the simplest convention that serves
  the games we have; add machinery only when a real package needs it.

## Decision

A game package is organised **by kind**: a small set of conventional directories, one
per artifact kind, each holding several grouped files the loader globs and merges. The
manifest shrinks to identity + entry points + cross-cutting settings; bulk content is
discovered by convention. Concretely:

### 1. Lua: a `scripts/` directory, one entry, modules via a VFS-scoped `require`

- The canonical home is **`scripts/`** (reconciling the divergence in favour of the
  `chronicle`/`sandbox` scaffold — the flat-root `rules.lua` is the form that moves).
- The manifest names **one entry** — `.script = "scripts/rules.lua"` — which is loaded
  as the Sim's single event-handler table exactly as today (ADR 0003 §1). The event
  model does not change: still one handler table per Sim, still no per-entity-per-frame
  callback.
- The entry composes sibling modules with an engine-provided **`require`**:
  `local ghosts = require("ghosts")` resolves to `scripts/ghosts.lua` within the
  package. Each module is an ordinary sandboxed Lua file that `return`s a table; the
  entry stitches their handlers/helpers into the one table it returns.

  This is the **"VFS-scoped `require`" ADR 0003 §Deferred anticipated**, now specified:

  - The engine installs its *own* `require` closure into each script's `_ENV`
    allowlist (ADR 0003 §7) — **not** Lua's stdlib `package`/`require`, which stays
    removed. It is a new sandbox-`_ENV` builtin (alongside `pairs`, `type`, …), not an
    addition to the versioned `mana.*` surface, so `mana.version` is unaffected; it is
    nonetheless a sandbox-contract change and is recorded here.
  - **Resolution is VFS-scoped and closed:** a module name maps to
    `scripts/<name>.lua` (dots → path separators, e.g. `require("ai.blinky")` →
    `scripts/ai/blinky.lua`) *within the package root only*. No `..`, no absolute
    paths, no reaching another package or an engine file — preserving ADR 0003 §7's
    "a script cannot touch the filesystem." A name that escapes or misses is a content
    error (warn + `nil`, honest-failure like an unknown prototype), never a crash.
  - **Determinism:** modules load lazily on first `require` into a per-`lua_State`
    (per-sim, ADR 0003 §8) module cache — same source + same event order ⇒ same load
    order ⇒ identical state. A module is evaluated once and cached; cycles are a
    content error. Because resolution is a pure VFS lookup with no wall-clock or
    external I/O, it adds nothing nondeterministic.
  - **Hot reload:** editing *any* script file clears the per-sim module cache and
    re-evaluates the entry, extending ADR 0003 §8's atomic-swap to the module graph;
    durable state already lives in components (ADR 0003 §8), so no migration dance.
    All `scripts/**` files join the `watchPaths` set.

### 2. ZON data: a `prototypes/` directory the loader globs and merges

- `prototypes.zon` (one blob) becomes **`prototypes/`**, a directory of grouped files
  each in the *unchanged* `.{ .prototypes = .{ … } }` shape (ADR 0016). The loader
  globs `prototypes/*.zon`, parses each, and **concatenates their `.prototypes` lists**
  into the one `PrototypeRegistry` it already builds.
- **Ordering:** files are loaded in **byte-lexicographic order of their package-
  relative path**, and within a file in declared order — a total, OS-independent order
  the loader imposes explicitly (the determinism constraint above). Registration order
  is therefore stable and hashable.
- **Collision:** a duplicate prototype **name** across files is a **hard load error**
  (fail loud, name the two files) — never last-wins, which would make registration
  order silently meaningful.
- **Scenes** (already a `scenes/` directory): `entry_scene` still names the start
  scene explicitly (the loader only materialises the entry today), and additional
  scenes are discovered by globbing `scenes/*.zon` for the hot-reload/transition set,
  same sort rule. **Sprites** stay reference-pulled (a `sprite.sheet` string in
  scene/prototype data) — no change; `sprites/` is not globbed because nothing consumes
  an un-referenced sheet. **HUD** stays a single named `hud.zon` (one screen today);
  it earns a `hud/` directory only when a game has several screens (add-when-needed).

### 3. Grouping axis — **by-kind**, not by-feature (the core fork)

Two ways to cut a package:

- **By-kind** (recommended): `scripts/`, `prototypes/`, `scenes/`, `sprites/` — group
  by *artifact type*, split *within* a kind by feature (`prototypes/ghosts.zon`,
  `scripts/ghosts.lua`).
- **By-feature**: a `ghosts/` folder bundles `ghosts.lua` + `ghosts.zon` + the ghost
  sheets together; the loader walks the tree and merges by extension/kind.

**We choose by-kind**, because it is the only one that fits every invariant *today*
without new machinery:

- It **matches the loader and the manifest**, which are already kind-shaped
  (`scenes`/`prototypes`/`script`/`hud` fields, one registry per kind) and matches the
  `scripts/`/`assets/` scaffold two packages already ship — one convention, minimal
  churn, no cross-cutting walk.
- The engine **stays genre-agnostic**: it knows a fixed set of *kinds* and a glob
  convention, never a game's feature vocabulary. By-feature would tempt the loader to
  reason about feature folders — a genre concept leaking toward `src/` (invariant #6).
- **Hot-reload granularity is identical** either way (both reload per file), so
  by-feature buys nothing there.
- Its one real cost — **review-diff locality**: a feature touches several kind-dirs at
  once — is not felt at current scale (a Pac-Man ghost change is `scripts/ghosts.lua` +
  maybe `prototypes/ghosts.zon`, two files), and by-feature is **speculative
  flexibility** (CLAUDE.md) until a game is big enough to feel the pain.

If a future large game *demonstrates* that pain, by-feature (or a hybrid) is revisited
**by ADR with that game as the evidence** — the "second concrete impl planned, or
don't abstract" rule. This ADR does not preclude it; it declines to build for it now.

### 4. Manifest role: convention over configuration for bulk, explicit for entry points

- The manifest keeps what genuinely needs naming or is cross-cutting: `name`,
  `version`, `entry_scene`, the script **entry** (`.script`), `script_api`,
  `projection`, `native_module`. These are identity, the one start scene, and settings
  that apply to the whole package.
- It **stops enumerating bulk content**: the redundant `scenes: []const []const u8`
  list and the single-file `.prototypes`/`.hud` paths give way to **globbing the
  conventional `prototypes/`, `scripts/`, `scenes/` directories**. Adding a prototype
  file or a script module needs no manifest edit — the file's presence *is* the
  declaration (files-are-truth).
- Because `data.parseLenient` ignores unknown fields, an older runner still parses a
  new-style `game.zon`; the loader change (globbing) is what gates the new layout, not
  the manifest schema.

### 5. Invariants preserved

- **Files are truth / headless:** every artifact stays a human-editable ZON/Lua file;
  the loader remains pure file reads (glob + read + parse), no editor required.
- **Per-file hot reload gets *finer*:** a changed `prototypes/ghosts.zon` re-globs and
  re-merges just the registry; a changed `scripts/ghosts.lua` re-swaps the module
  graph — the whole tree is watched, but reload is per file, never coarser than today.
- **Engine stays genre-agnostic:** the loader learns *kinds* + a *sorted-glob*
  convention; it never learns a game or a feature.
- **Deterministic load order:** globs are sorted byte-lexicographically before parse/
  register; module `require` resolves through a per-sim cache with no external I/O — so
  the state hash is unchanged by *where* content is split, only by *what* it is.

### 6. Migration: a hard cutover for the in-repo corpus, no long-term back-compat

- `pacman`/`snake` migrate in the loader-landing PR: `rules.lua` → `scripts/rules.lua`
  (optionally split into modules); `prototypes.zon` → `prototypes/*.zon`; `scenes/`
  already conforms; the manifest drops its now-conventional bulk fields.
  `chronicle`/`sandbox` already have the `scripts/` shape and just gain real files as
  they grow.
- **The monolithic form is not kept long-term.** With a four-package in-repo corpus,
  maintaining two loader paths (single-file *and* globbed) is exactly the speculative
  flexibility CLAUDE.md forbids. The follow-up loader work **may** support both for one
  transitional commit purely to keep the migration reviewable, then delete the single-
  file path — a hard cutover, not a permanent compatibility layer. (No external mod
  packages exist yet, so there is no third-party contract to deprecate on a timeline;
  if one ever does, that is a versioning decision for its own ADR.)

### Illustrative final tree (`games/snake`)

*Illustrative only — this ADR moves no files.*

```
games/snake/
  game.zon              # name, version, entry_scene, .script="scripts/rules.lua",
                        #   script_api, projection — no bulk file lists
  scripts/
    rules.lua           # entry: returns the one handler table; requires the modules
    movement.lua        # require("movement") — grid step + turn/reverse-reject
    food.lua            # require("food")     — spawn / eat / grow
  prototypes/
    snake.zon           # head + segment templates  (.{ .prototypes = .{…} })
    pickups.zon         # food template
    walls.zon           # wall template
  scenes/
    board.zon           # entry scene
  sprites/
    head.zon
    segment.zon
    food.zon
    generated/          # gitignored derived .msf/.png (mise run assets)
  assets/
```

## Alternatives considered

- **Keep the monolith (do nothing).** Rejected: the problem — a 300-line `rules.lua`
  and a 188-line `prototypes.zon` colliding in one file and one diff — is present now
  and grows with every game; "one blob per kind" has no path to scale.
- **By-feature grouping** (a `ghosts/` folder bundling lua + data + sheets). Its
  strength is review-diff locality (one feature = one folder) and a mod that adds a
  feature drops in one directory. Rejected for now because it needs a tree-walking,
  extension-classifying loader (more machinery), tempts the engine toward feature-aware
  reasoning (genre leak, invariant #6), and buys nothing on hot-reload granularity —
  all to solve a locality cost not yet felt at our scale. Reconsidered by ADR when a
  concrete large game is the evidence.
- **Manifest enumerates every file explicitly** (extend today's model — a `scripts:
  []` list beside `scenes: []`). Rejected: it makes the manifest a second, hand-
  maintained index of the filesystem that silently rots when a file is added and
  forgotten; convention-over-configuration globbing keeps the files themselves the
  single source of truth (invariant #1). Explicit entry points (`entry_scene`, the
  script entry) stay named because they are *not* discoverable — there is genuinely one
  distinguished start scene and one handler-table entry.
- **`require` via Lua's stdlib `package.searchers`.** Rejected: it reopens the
  filesystem/`package` surface ADR 0003 §7 deliberately sealed. The engine-owned,
  VFS-scoped `require` closure gives multi-file composition while keeping the sandbox
  closed to everything outside the package's `scripts/`.
- **A single concatenated `prototypes.zon` with in-file section markers** (split
  visually, one file physically). Rejected: it does not give per-file hot reload or
  per-file review diffs — the actual wins — and invents a sub-file format the ZON
  parser would have to learn.
- **Last-writer-wins on duplicate prototype names.** Rejected: it makes the (sorted)
  file load order silently semantic and lets a stray duplicate shadow a real template
  with no error. A duplicate name is a bug; the loader says so.

## Consequences

- **Easier:** a package scales by adding grouped files, not by growing blobs; a feature
  change is a small, local diff (`scripts/ghosts.lua`, not a 300-line file); prototypes
  hot-reload and review per group; adding content needs no manifest bookkeeping (drop
  the file in the conventional dir). The engine gains exactly one new content-loading
  idea — *sorted-glob a conventional directory* — reused across kinds.
- **Harder / accepted:** the loader must impose a deterministic sort on every glob (the
  determinism-critical detail); a VFS-scoped `require` is a new sandbox-`_ENV` builtin
  the script layer must implement and keep closed; the four in-repo games and their
  goldens migrate in one reviewed slice; by-kind's review-locality cost is accepted now
  and revisited only with a real large game as evidence.
- **Committed to (once accepted):** by-kind grouping; `scripts/` with one manifest-
  named entry + engine-owned VFS-scoped `require`; `prototypes/` globbed, sorted,
  merged, duplicate-name = error; convention-over-configuration globbing of the bulk
  directories with the manifest reduced to identity + entry points + cross-cutting
  settings; a hard cutover off the monolithic form.
- **Explicitly NOT done here (follow-up, phased, gated on this ADR's acceptance —
  issue #178):** no loader implementation (the glob/sort/merge path, the `require`
  builtin, the manifest slimming) — this ADR is phase 1, the *direction*; no game
  migration (moving `pacman`/`snake` files, updating goldens); no concrete manifest
  field-list edit or `Manifest` struct change; no `sprites/`-globbing or multi-screen
  `hud/` (add-when-needed); no by-feature layout (deferred to its own ADR + a game that
  needs it). This ADR fixes the *convention and constraints* those follow-ups must fit,
  not their code.

Cross-references: #178 (this decision, phase 1); builds on ADR 0003 (Lua scripting
API / sandbox — this ADR realises its §Deferred "VFS-scoped `require`"), ADR 0004
(scene/entity schema + determinism), ADR 0005 (file-watch / hot-reload), ADR 0016
(prototypes as package ZON + registry), ADR 0018 (a game is data), ADR 0034 (the
data-driven HUD this layout houses). Invariants applied: #1 (files are truth), #2 (hot
reload), #5/#6 (engine is genre-agnostic; genre lives in content).
