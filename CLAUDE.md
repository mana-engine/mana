# mana — engine guide (read every session)

3D isometric game engine in Zig → native Linux + Windows, Vulkan (vulkan-zig + VMA
+ dynamic rendering). Headless-first, data/script-driven, genre-agnostic.

## Vision invariants (never violate)
1. **Files are the source of truth.** Scenes, entities, node graphs, abilities,
   pipelines live in human-editable ZON. Engine runs headless from files alone.
   Editors are optional *clients* of those files. GUI-only features are bugs.
2. **Data- and script-driven.** Content lives in data + scripts, not compiled code.
   Hot reload is first-class.
3. **Performance is first-class.** No per-frame heap alloc in the hot loop; explicit
   allocators; cache-friendly ECS iteration; Tracy hooks from day one.
4. **Vulkan never leaks upward.** All GPU access goes through the `gpu` port. Nothing
   above `gpu` may import a Vulkan type.
5. **The game is a content package, not a fork.** A game = a dir of ZON + Lua + node
   graphs + assets with a `game.zon` manifest. Runner is the exe; `mise run run --
   games/sandbox`. Engine has zero knowledge of any specific game. A game may opt into
   a native module (versioned C-ABI dylib: init/tick/shutdown + engine API ptr) —
   rare, hot-path only. Mods fall out for free (another package layered on top).
6. **Genre lives in content, not `src/`.** Features are justified by a real game
   package's concrete need, never speculatively. No genre concept leaks into `src/`.

## Module import DAG (violations are build errors, not shortcuts)
```
core → (nothing above; only std)
data, ecs, gpu, platform, script → core
gpu → may import Vulkan (ONLY place); null backend is the real default
platform → SDL3 adapter (deferred); headless adapter is the real default
engine → core + data + ecs + gpu + platform  (+ script once its ADR lands)
runtime (exe) + tools → engine
```
`runtime` knows the `game.zon` *format* only. **Nothing in `src/**` may reference
`games/**`.** ImGui (zgui) only in `tools/` + debug overlays, never game UI.

## Game/engine boundary & scripting
- **Lua decides *what*; engine executes *how*.** Native (Zig): everything
  per-entity-per-frame at scale — rendering, ECS iteration, collision, pathfinding,
  steering, animation, particles, audio. Lua: event-driven, rule-shaped — abilities/
  boons, AI decisions (selection not steering), encounter/room/dialogue/UI logic,
  meta-progression.
- **Lua never iterates all entities per frame.** Engine dispatches events (`on_spawn`,
  `on_hit`, `on_death`, `on_collision_begin`, `on_room_enter`, timers); Lua sets data
  the engine consumes. A per-frame per-entity Lua callback is wrong.
- **Prefer data over Lua.** If a behavior is expressible as a ZON definition the engine
  interprets, it belongs in data (hot-reloadable, diffable, node-graph-editable). Lua
  is for genuinely bespoke logic; native modules are the last resort.
- **One small, versioned scripting API**, opaque entity handles (never raw pointers).
  Every addition needs an ADR. Script dispatch is Tracy-zoned and budgeted;
  consistently over budget ⇒ promote to native (measurement, not gut feel).
- Interpreter: plain **Lua 5.4** via ziglua (not LuaJIT). Revisit only via ADR.

## Architecture & abstraction policy
- **Hexagonal edges, data-oriented core.** Sim is pure/deterministic (state in, state
  out; no OS imports). Edges = a small fixed set of ports (`gpu`, `platform`, `audio`,
  `physics`, file-watch) with adapters chosen at **comptime** via build options, not
  runtime DI. Abstraction granularity is the subsystem, never the class.
- **Core is DOD:** entities are IDs; components are plain data in contiguous SoA
  arrays; systems are free functions in cache order. No behavior-objects, no observers/
  virtual dispatch in the hot path.
- **Abstract only where we own the concept and the dependency is load-bearing** (gpu,
  platform, audio, physics). Do **not** abstract where the file format already isolates
  us (tools are disposable ZON clients). Never build a common interface over libraries
  with different shapes (e.g. UI libs).
- **No speculative flexibility.** Indirection needs a measured/concrete need in an ADR.
  Compare libraries via *spikes* (build twice, measure, delete the loser), never a
  permanent "keep options open" layer. Second concrete impl planned, or don't abstract.
- **The null GPU backend is the only test double** — a real adapter.

## Physics & VFX
- Invariant: **deterministic within the sim, or cosmetic and excluded from the state
  hash.** Every physical/visual system declares its side.
- Physics is a port. First adapter: hand-rolled 2.5D (circle/capsule vs static geom,
  spatial-hash broad-phase), trivially deterministic. Box2D/Jolt may slot behind it
  later when a game needs dynamics. Don't implement more physics than a game exercises.
- Particles/VFX are content (ZON: emitters, curves, colors, forces) — hot-reloadable,
  a node-graph target. Sim spawns named emitters by reference; never touches particles.
  Execution is render-side (CPU sprite batcher → GPU compute later, same ZON format).

## Behavior (how I work here)
- **Plan → approve → implement → verify.** State plan + files before non-trivial edits.
  After implementing, run `mise run check` and report actual output. Never "done"
  without green tests. Never bypass hk (`HK=0`, `--no-verify`) without asking.
- **Small diffs**, one concern. >~300 lines ⇒ stop and propose a split.
- **Never weaken/skip/delete a failing test** without explicit permission; say whether
  the code or the spec is wrong.
- **ADR for design decisions** (new dep, module boundary, file-format change) in
  `docs/adr/NNNN-title.md`; reference it in the commit.
- **Read before you write.** Read a module + its tests fully before modifying.
- **Ask, don't assume** on ambiguity. One precise question beats a wrong build.

## Code hygiene
- `zig fmt` is law. `TitleCase` types, `camelCase` fns, `snake_case` vars/fields.
- Every public fn/type gets a `///` doc: purpose, ownership/lifetime of params, errors.
- Allocators passed explicitly; no hidden global alloc; arenas for per-frame/per-load.
- Errors are values (error unions); never `catch {}`. `unreachable` only with a proof
  comment. No dead or commented-out code in commits.
- Soft limits: files ~500 lines, functions ~60 — exceed only with a justifying comment.

## Testing
- Design for testability: sim logic pure (state in/out, no I/O/globals) ⇒ deterministic.
- Unit tests in-file in `test` blocks; a module without tests for its public API is
  incomplete. Name by behavior: `test "iso projection: origin maps to screen center"`.
- Table-driven tests for math/coords (identity, edge, negative). **Round-trip property
  tests** for the serializer (`parse(serialize(x)) == x`) — never regress.
  **Golden-file tests** in `tests/fixtures/` (update only via explicit reviewed step;
  a hook blocks casual edits). **Determinism test** in CI (same seed+inputs ⇒
  bit-identical state hash after N ticks).

## Toolchain & tasks (mise is the single source of truth)
- Pinned in `mise.toml`: **zig 0.16.0**, **zls 0.16.0**, **hk 1.50.0**. `HK_MISE=1`.
  Fresh machine: `mise install` (postinstall self-installs git hooks via `hk install
  --mise`).
- **All commands are mise tasks** (CLAUDE.md, hk, CI, humans call the same):
  - `mise run build` — compile engine + runner (native).
  - `mise run test` — all unit + integration tests.
  - `mise run fmt` / `fmt-check` — format in place / verify (no write).
  - `mise run check` — fmt-check + build + test (the canonical green gate).
  - `mise run run -- games/sandbox` — headless runner.
  - `mise run cross-win` — `-Dtarget=x86_64-windows` portability gate.
- **Quiet on success, loud on failure** — tasks print a summary line on pass, full
  detail only on fail. Never paste large logs into chat; write to a file and grep it.
- hk: pre-commit = zig fmt (fix) + `mise run build`; pre-push = `mise run check`.
- Claude Code hooks: PostToolUse zig-fmt edited file; PreToolUse blocks
  `tests/fixtures/**` unless `MANA_UPDATE_GOLDENS=1`; Stop runs `mise run test`. Hook
  scripts are host Python (`.claude/hooks/`), separate from the mise build toolchain.

## Context economy
- Concise responses: no preamble/filler/re-narration. Show the changed region, not
  whole files. Summaries only at task completion or when asked.
- Delegate codebase lookups ("where does X handle Y") to a subagent that returns a
  short summary. Read surgically (grep + line ranges), don't slurp whole files.
- Keep this file dense. Per-directory READMEs hold subsystem detail, loaded on demand.

## Definition of done
- [ ] Builds native **and** `-Dtarget=x86_64-windows` (`mise run cross-win`).
- [ ] `mise run check` green (fmt-check + build + all tests, incl. determinism).
- [ ] hk hooks pass (no bypass).
- [ ] Docs updated (module READMEs / this file) and an ADR written if a design
      decision was made.
- [ ] New public API has `///` docs + behavior-named tests.

## Deferred (stubs today; each needs its own task + ADR before wiring)
Vulkan gpu backend, SDL3 platform adapter, ziglua scripting, Tracy, VMA. Selecting a
deferred backend (`-Denable-vulkan` / `-Denable-sdl3`) fails the build on purpose.
**Scripting API contract:** ADR 0003 (accepted) fixes the Lua API table, event
list, opaque handle semantics, versioning, sandbox, state/hot-reload, and error
policy. `src/script` must implement exactly that; any surface change needs a new
ADR. Building it is a separate task that adds the ziglua dependency (ask first).

## Hard-won knowledge (append when learned the hard way)
- **Zig 0.16 build API:** `b.addExecutable(.{ .name, .root_module = b.createModule(
  .{ .root_source_file, .target, .optimize, .imports }) })`. Internal modules via
  `b.createModule` + `mod.addImport(name, dep)`. Tests are per-module:
  `b.addTest(.{ .root_module = m })` — one compilation unit at a time, so add a test
  run per module (a module's root file pulls in its sibling files' tests).
- **`build.zig.zon` (0.16):** `.name` is an enum literal (`.mana`), requires a
  `.fingerprint` (omit it once, run `zig build`, paste the suggested value).
- **Zig 0.16 I/O reorg:** `std.fs.File` moved to **`std.Io.File`**. Writing to stdout:
  construct an `Io` first — `var t: std.Io.Threaded = .init(gpa, .{}); const io =
  t.io();` — then `var w = std.Io.File.stdout().writer(io, &buf); const out =
  &w.interface; try out.print(...); try out.flush();`. `writer()` now takes the `io`.
- **`@compileError` diverges (noreturn):** put it directly as an `if` branch
  (`if (cond) @compileError("…") else .value`); a following `break :blk x` is
  unreachable-code error.
- **Windows/mise:** a new `mise.toml` must be `mise trust`ed before tools resolve.
- **`zig build test` does not compile `pub fn main`.** In test mode only `test`
  blocks and decls they reference are compiled; `main` (and anything only it calls)
  is skipped. An API misuse reachable only from `main` passes `zig build test` and
  fails `zig build` (install). This is exactly why `check` runs *both* build and
  test, and why hk pre-commit compiles as well as tests. Don't trust a green `test`
  alone for runner/entry-point code.
- **Zig 0.16 sleep:** `std.Thread.sleep` is gone. Use `std.Io.sleep(io, dur, clock)`
  with `Io.Duration.fromMilliseconds(n)` and clock `.awake` (the monotonic one;
  members are `real`/`awake`/`boot`/`cpu_process`/`cpu_thread`).
- **Zig 0.16 fs moved under `Io`:** `std.Io.Dir` (`.cwd()`, `openFile`,
  `statFile(io, path, .{})` → `Stat` with `size`/`mtime.nanoseconds`,
  `readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0)` for a `[:0]u8`,
  `writeFile(io, .{ .sub_path, .data })`, `deleteFile`). `std.testing.io` +
  `std.testing.tmpDir(.{})` give a real Io and temp dir for file tests.
- **Subsystem-scoped knowledge lives in per-directory `CLAUDE.md` files** (loaded
  only when working there), so this root stays lean. Vulkan / vulkan-zig / shader
  gotchas → `src/gpu/CLAUDE.md`. Add new package-specific lessons to that package's
  `CLAUDE.md`, not here; keep this section to project-wide Zig/tooling facts.
