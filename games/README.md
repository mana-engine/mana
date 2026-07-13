# games

**Responsibility:** Content packages. A game is a directory of ZON files, Lua
scripts, node graphs, and assets with a `game.zon` manifest at its root — **not a
fork of the engine**. The engine runner is the executable; running a game is
`mise run run -- games/<name>`. A mod is another content package layered on top.

The engine never contains knowledge of any specific game. `games/sandbox/` is the
first real package: it grows alongside the engine as the proof that engine
features serve concrete needs, and doubles as the integration-test corpus.

`games/chronicle/` is the second package: a genre-neutrality test. It reuses the
exact same built-in components (`transform`, `velocity`, `health`) as sandbox but
shapes them into a dialogue/inventory/save-archive feel instead of sandbox's
combat feel — proof the engine carries no genre assumptions. See its README for
the specifics.

## Running & playing the samples (Linux **and** Windows)

Every command below is a single `zig build` invocation and runs **verbatim** in bash,
PowerShell, and cmd — nothing here is shell-specific. (`scripts/games.sh` is a Unix-only
convenience wrapper around these exact commands; the commands, not the script, are the
portable source of truth.) The toolchain is pinned by mise, so prefix with `mise x --`
to guarantee the pinned Zig, or drop the prefix if `zig 0.16` is already on your `PATH`.

All game logic is Lua, so **`-Denable-lua` is required** for every mode (plain
`mise run run` does *not* set it). Substitute `snake` for `pacman` for the other game.

```sh
# Build the engine + runner (headless, no window):
mise x -- zig build -Denable-lua

# Run headless — materialise the maze, tick the sim, print a deterministic state hash:
mise x -- zig build -Denable-lua run -- games/pacman

# PLAY IT — real-time window, arrow keys (needs SDL3 + a Vulkan-capable display):
mise x -- zig build -Denable-lua -Denable-sdl3 -Denable-vulkan run -- games/pacman --play

# Run one acceptance scenario (spawn → move → turn → eat → death → …):
mise x -- zig build -Denable-lua run -- games/pacman --scenario games/pacman/scenarios/01_spawn.zon

# Run the whole test suite (unit + every acceptance scenario, both games):
mise x -- zig build -Denable-lua test
```

**Playing (`--play`) prerequisites — per OS:**
- **Windows:** install the SDL3 runtime (`SDL3.dll` on `PATH`, or via `vcpkg`/an SDL3
  release) and a current GPU driver. Verified working on native Windows.
- **Linux:** install SDL3 dev + runtime (`sudo dnf install SDL3-devel` on Fedora,
  `libsdl3-dev` on Debian/Ubuntu) and a Vulkan ICD. Under WSL2 this uses **WSLg** for the
  window + Vulkan surface — a recent WSL provides both; check with `vulkaninfo`.
- The `--play` build compiles on both today; if your machine lacks SDL3/Vulkan at runtime,
  fall back to headless (the hash-printing run above) or the no-GPU preview below.

**Seeing a game without a GPU (CI / headless boxes):** a headless renderer can dump
frames you open in a browser — a single static frame (`--render-svg <file>`) or a
filmstrip over N ticks (`--filmstrip <dir> --ticks <n>`). This is a regression/CI aid,
not the intended way to judge how a game looks or feels — for that, `--play` it.

```sh
mise x -- zig build -Denable-lua run -- games/pacman --filmstrip ./out/pacman --ticks 30
```
