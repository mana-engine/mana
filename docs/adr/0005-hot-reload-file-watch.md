# 0005. File-watch port + hot-reload model

- Status: accepted
- Date: 2026-07-12

## Context

Hot reload is a first-class vision requirement and "editors are optional clients
that read and write the same files" — but files are the source of truth only at
startup today. Now that `scene → World` exists, we can close the loop: change a
scene file, the running world updates. File watching is one of the vision's named
edge ports, and `data`'s README already claims "file watching + hot reload."

This ADR fixes the watch mechanism, the reload model, robustness under mid-edit
files, and — critically — how hot reload relates to the determinism invariant.

## Decision

### 1. File watching is a port; first adapter = mtime+size polling

The watch mechanism is a port. The first (and only, for now) adapter **polls**:
it re-`stat`s each watched file and reports a change when **mtime or size** differs
from the last observation (size catches same-second edits that mtime resolution
misses). Rationale: dependency-free, cross-platform, and the simplest thing that
works — matching the "simplest first adapter, promote on measured need" policy.
Native OS watchers (inotify / ReadDirectoryChangesW / FSEvents) are future adapters
behind the same port when polling latency or cost is shown to matter.

- **Host-stepped, single-threaded.** The host loop calls `watcher.poll(io)`
  explicitly (e.g. once per frame / every N ticks); there is no background thread.
  This keeps it simple and free of thread synchronization, and makes reload timing
  explicit and controllable.
- **Watches explicit file paths** in v1 (the scene files, later any referenced ZON/
  asset). Directory watching (detecting *new* files) is a later adapter feature.

### 2. Reload model: full reload of the affected resource

On a detected change, the affected resource is **fully reloaded**: for a scene,
re-parse the ZON and **rebuild the `World`** from it. Reloads are applied at a
**tick boundary** (between ticks, never mid-tick) so systems never observe a
half-swapped world.

- **Stable-identity diff/patch** (preserving entity handles, applying only deltas)
  is explicitly **deferred to its own ADR** — it requires stable entity ids in the
  scene format, which we do not have yet. Full reload is correct and sufficient for
  the content-iteration loop; its tradeoff (runtime-only/transient component state is
  discarded on reload) is acceptable and usually desirable while iterating.

### 3. Robustness: last-good-wins on a broken file

If a changed file fails to parse (a syntax error saved mid-edit), the engine
**keeps the current world**, logs the error, and retries on the next change. A
reload never crashes the session and never installs a half-loaded world. This is
what makes the edit loop pleasant: save a broken file, keep running the last good
version, fix it, it reloads.

### 4. Determinism boundary

File watching is an **edge/tooling concern, excluded from the sim's determinism**:
- The mtime/size polling reads wall-clock-derived metadata and **never feeds the
  state hash**.
- Deterministic headless runs (the CI determinism test) **do not watch** — they load
  fixed content once (`@embedFile`), so they are unaffected.
- A reload is an **external input**, applied at a tick boundary. The determinism
  guarantee — same seed + same inputs ⇒ same state — holds *between* reloads, with
  each reload treated as one input event (like a keypress). Hot reload therefore does
  not weaken determinism; it is simply not part of a deterministic run.

### 5. Module placement

- The watch **mechanism** (`Watcher`: register paths, `poll` returns changed paths)
  lives in `data` — file I/O is `data`'s job; it uses `std` fs/`Io` and imports
  nothing above `core`.
- The reload **policy** (re-parse scene → rebuild `World`, last-good-wins) is
  `engine`/`runtime` glue that consumes the watcher. `data` stays mechanism-only.

### 6. Runner gains a `--watch` mode

The runner keeps its default one-shot headless behavior (load → N ticks → hash).
A new `--watch` mode runs a fixed-timestep loop that ticks, polls the watcher each
iteration, and hot-reloads on change until interrupted. The watcher and reload
policy are unit-testable headlessly (mutate a temp file, poll, assert reload)
without the interactive loop, so tests do not depend on `--watch`.

## Consequences

- **Easier:** the files-as-source-of-truth thesis becomes tangible — edit a scene,
  see it update live; a future viewport/node-graph editor is just another writer of
  the same files, reloaded by the same path.
- **Harder / accepted tradeoffs:** full reload discards transient runtime state (until
  the diff/patch ADR); polling has up-to-one-interval latency and inherits mtime
  resolution limits (mitigated by the size check; a content hash is a later option if
  needed).
- **Committed to:** a host-stepped polling `Watcher` in `data`, a last-good-wins
  scene-reload path in `engine`/`runtime`, and a `--watch` runner mode. Native OS
  watch adapters, directory watching, stable-identity diff/patch, and watching
  non-scene assets are named follow-ons, each with its own ADR when a concrete need
  arrives.
