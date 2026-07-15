# 0038. Game package layout: modular, grouped content over monolithic blobs

- Status: accepted
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

A game package is organised as a **flexible hybrid**: a **by-kind baseline** — a small
set of conventional directories, one per artifact kind, each holding several grouped
files the loader globs and merges — **plus optional feature folders** that let a heavy
feature or entity co-locate its own Lua + data + assets (§3). The manifest shrinks to
identity + entry points + cross-cutting settings; bulk content is discovered by
convention. Concretely:

> **Standing steer (user, 2026-07-15): layout is the game developer's call.** This ADR
> only *suggests* a convention; it must never *mandate* one. The load-bearing job of the
> engine here is to make the recommended shape **efficient and zero-ceremony** (sorted
> globbing that merges whatever conventional directories/feature folders a package
> chooses to use) — not to police a package's internal structure. Where a rule below
> reads as prescriptive it is a *guideline + the efficient path the loader supports*, and
> the concrete mechanics (§3) are deliberately left to the implementation and the game
> author's judgement.

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
  into the one `PrototypeRegistry` it already builds. (Under the hybrid of §3, a
  prototype file co-located inside a heavy feature's folder — e.g. `player/player.zon`
  — merges into the same registry under these same rules; a prototype is a prototype
  wherever it lives.)
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

### 3. Grouping axis — **a flexible hybrid** (the core fork)

Three ways to cut a package:

- **By-kind only:** `scripts/`, `prototypes/`, `scenes/` — group strictly by *artifact
  type*; a feature is split *within* each kind (`prototypes/ghosts.zon`,
  `scripts/ghosts.lua`).
- **By-feature only:** every folder is a feature (`ghosts/` holds `ghosts.lua` +
  `ghosts.zon` + sheets); there are no kind-directories.
- **Hybrid (recommended):** by-kind is the **baseline**, and a *heavy* feature or
  entity may **opt into its own folder** that co-locates its Lua + data + assets.

**We recommend the hybrid.** The forces genuinely pull both ways, so a single rigid
axis is the wrong commitment:

- **Small stuff wants by-kind.** Most content is light — Pac-Man's HUD flash, Snake's
  food rule — and a kind-directory (`scripts/`, `prototypes/`) is the least-ceremony
  home for it. This baseline matches the already-kind-shaped loader/manifest
  (`scenes`/`prototypes`/`script`/`hud` fields, one registry per kind) and the
  `scripts/`/`assets/` scaffold two packages already ship.
- **Heavy features want locality.** A `player/` accretes a lot — its script, its
  prototype(s), its sprites, later its abilities and UI — and so does a `boss/`. For
  those, scattering the pieces across four kind-directories hurts review-diff locality
  and comprehension; a self-contained `player/` folder that holds `player.lua` next to
  the player's prototypes is the maintainable shape. The hybrid lets a package reach
  for that folder **exactly when the weight justifies it**, without forcing every
  trivial rule into a folder of its own.
- **The loader treats both uniformly**, so the flexibility costs almost nothing: it
  globs the kind-directories **and** any feature folders, and merges everything under
  the *same* rules already fixed in §1–§2 — deterministic byte-lexicographic sort over
  package-relative paths, `.{ .prototypes = .{…} }` lists concatenated into the one
  registry, a duplicate prototype **name** a hard load error regardless of which folder
  it came from, and `require` resolving a co-located `player/ai.lua` the same VFS way.
  A prototype is a prototype and a script is a script wherever it sits; the engine still
  knows only *kinds* and a glob convention — never a feature name — so invariant #6
  holds (a `player/` folder is content the loader globs, not a concept `src/` learns).

**Neither rigid axis is right:** by-kind-only makes a heavy entity's content
permanently non-local (the cost the user flagged: "a player might need a folder since
it will have tons of stuff, boss as well"); by-feature-only forces even one-line rules
into folders and throws away the kind-baseline the loader already fits. The hybrid
takes the good half of each.

**The specifics are the implementation's to decide** (the user's steer: "might be worth
letting the implementation decide"). This ADR fixes only the *principle* — a by-kind
baseline plus optional feature-folder co-location for heavy features, all merged under
the §1–§2 rules. It deliberately does **not** pin: how deeply feature folders may nest;
the exact glob/merge precedence between a kind-directory and a feature folder; whether a
feature folder may also carry its own `scenes`/HUD or only scripts+prototypes+assets;
or the naming convention that marks a directory as a feature folder vs a kind-directory.
Those are decided when the loader is built, against the first game that actually grows a
heavy feature, and **recorded as an amendment to this ADR** — keeping the direction
principle-based and letting real content, not speculation, settle the mechanics.

### 4. Manifest role: convention over configuration for bulk, explicit for entry points

- The manifest keeps what genuinely needs naming or is cross-cutting: `name`,
  `version`, `entry_scene`, the script **entry** (`.script`), `script_api`,
  `projection`, `native_module`. These are identity, the one start scene, and settings
  that apply to the whole package.
- It **stops enumerating bulk content**: the redundant `scenes: []const []const u8`
  list and the single-file `.prototypes`/`.hud` paths give way to **globbing the
  conventional kind-directories (`prototypes/`, `scripts/`, `scenes/`) and any feature
  folders** (§3). Adding a prototype file or a script module needs no manifest edit —
  the file's presence *is* the declaration (files-are-truth). The exact rule for how the
  loader recognises a feature folder is left to the implementation (§3).
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

### Illustrative final tree (`games/pacman`, hybrid)

*Illustrative only — this ADR moves no files, and the exact feature-folder rules are
the implementation's to settle (§3).* The small, light content stays in
kind-directories; the ghosts — a heavy feature (four AIs, their prototypes, their
sheets) — opt into a co-located `ghosts/` folder.

```
games/pacman/
  game.zon              # name, version, entry_scene, .script="scripts/rules.lua",
                        #   script_api, projection — no bulk file lists
  scripts/              # kind-directory — the light, cross-cutting rules
    rules.lua           # entry: returns the one handler table; requires the modules
    input.lua           # require("input")  — on_key → pac heading
    modes.lua           # require("modes")  — scatter/chase/frightened timing
  prototypes/           # kind-directory — the light templates
    pac.zon             # the player template  (.{ .prototypes = .{…} })
    walls.zon           # static wall template
  ghosts/               # FEATURE FOLDER — a heavy entity co-locating its own stuff
    ghosts.lua          # require("ghosts.ghosts") — Blinky/Pinky/Inky/Clyde targeting
    ghosts.zon          # the four ghost prototypes  (.{ .prototypes = .{…} })
    generated/          # ghost sheets (gitignored, mise run assets)
  scenes/
    maze.zon            # entry scene
  sprites/
    pac.zon
    generated/          # gitignored derived .msf/.png (mise run assets)
  assets/
```

A leaner package (Snake today) needs no feature folder at all — `scripts/` +
`prototypes/` + `scenes/` is the whole story. The hybrid is *opt-in weight*, not a
mandate.

## Alternatives considered

- **Keep the monolith (do nothing).** Rejected: the problem — a 300-line `rules.lua`
  and a 188-line `prototypes.zon` colliding in one file and one diff — is present now
  and grows with every game; "one blob per kind" has no path to scale.
- **By-kind only** (rigid — no feature folders ever). Its strength is uniformity and
  the least machinery. Rejected as the *sole* rule because it makes a heavy entity's
  content permanently non-local: a `player` or a `boss` that accretes a script, several
  prototypes, sprites, and later abilities/UI ends up smeared across four kind-
  directories with no home — the exact cost the recommendation's hybrid fixes by letting
  such a feature opt into its own folder. By-kind survives as the hybrid's *baseline*,
  not its ceiling.
- **By-feature only** (rigid — every folder is a feature, no kind-directories). Its
  strength is maximal locality. Rejected as the *sole* rule because it forces even a
  one-line rule or a single shared template into a folder of its own, throws away the
  kind-baseline the loader/manifest already fit, and needs the loader to treat all
  directories as features. The hybrid keeps by-feature available *where the weight earns
  it* without imposing it everywhere.
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

- **Easier:** a package scales by adding grouped files, not by growing blobs; light
  content stays a small kind-directory diff and a heavy feature co-locates into one
  folder (`ghosts/`, `player/`) instead of smearing across four; prototypes hot-reload
  and review per group; adding content needs no manifest bookkeeping (drop the file in
  a conventional dir). The engine gains one new content-loading idea — *sorted-glob the
  kind-directories and any feature folders, merge under uniform rules* — reused across
  kinds.
- **Harder / accepted:** the loader must impose a deterministic sort on every glob (the
  determinism-critical detail) and merge kind-directories and feature folders uniformly;
  a VFS-scoped `require` is a new sandbox-`_ENV` builtin the script layer must implement
  and keep closed; the four in-repo games and their goldens migrate in one reviewed
  slice; the precise feature-folder mechanics stay open until the implementation settles
  them against a real heavy feature.
- **Committed to (once accepted):** the **hybrid** — a by-kind baseline
  (`scripts/`/`prototypes/`/`scenes/`) plus optional feature-folder co-location for
  heavy features; `scripts/` with one manifest-named entry + engine-owned VFS-scoped
  `require`; ZON globbed, byte-lexicographically sorted, merged, duplicate prototype
  name = error, applied uniformly to kind-directories and feature folders;
  convention-over-configuration globbing with the manifest reduced to identity + entry
  points + cross-cutting settings; a hard cutover off the monolithic form.
- **Explicitly NOT done here (follow-up, phased, gated on this ADR's acceptance —
  issue #178):** no loader implementation (the glob/sort/merge path, the `require`
  builtin, the manifest slimming) — this ADR is phase 1, the *direction*; no game
  migration (moving `pacman`/`snake` files, updating goldens); no concrete manifest
  field-list edit or `Manifest` struct change; no `sprites/`-globbing or multi-screen
  `hud/` (add-when-needed); and — per the user's steer — **no over-specified
  feature-folder mechanics**: how folders nest, the kind-dir↔feature-folder glob/merge
  precedence, whether a feature folder may carry scenes/HUD, and the folder-vs-kind
  naming rule are left to the implementation and **recorded as an amendment to this
  ADR** against the first game that grows a heavy feature. This ADR fixes the
  *principle and constraints* those follow-ups must fit, not their code.

Cross-references: #178 (this decision, phase 1); builds on ADR 0003 (Lua scripting
API / sandbox — this ADR realises its §Deferred "VFS-scoped `require`"), ADR 0004
(scene/entity schema + determinism), ADR 0005 (file-watch / hot-reload), ADR 0016
(prototypes as package ZON + registry), ADR 0018 (a game is data), ADR 0034 (the
data-driven HUD this layout houses). Invariants applied: #1 (files are truth), #2 (hot
reload), #5/#6 (engine is genre-agnostic; genre lives in content).
