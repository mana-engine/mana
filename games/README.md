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

`games/menu/` (issue #135) is the first *interactive* UI package: a navigable main
menu + settings screen built on the widget/layout + focus-navigation + `on_click`/
`on_focus`/`on_activate` dispatch (ADR 0034, ADR 0039), with settings values that
persist to a ZON file. See its README for the details and the current runner-
integration gap.

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

### Playing (`--play`) prerequisites

SDL3 is **built from source** (the `castholm/SDL` Zig port) and statically linked — there
is **no system SDL3 to install**. But `--play` is built with `-Denable-vulkan`, so the
window is created with the Vulkan flag, and at runtime SDL `dlopen`s the OS window/input
client libraries and needs a working Vulkan loader + driver. Those runtime libraries are
what you install.

- **Windows (native):** nothing extra beyond a current GPU driver (which ships a Vulkan
  ICD). Run from PowerShell/cmd. Verified working.
- **Linux / WSL2 (Fedora):**
  ```sh
  # Window + input client libs SDL dlopens (libxkbcommon is usually already present):
  sudo dnf install -y libwayland-client libwayland-cursor libwayland-egl libdecor \
                      libX11 libXext libXcursor libXi libXrandr libXfixes
  # Vulkan loader + driver (the --play window needs a Vulkan ICD to be created):
  sudo dnf install -y vulkan-loader mesa-vulkan-drivers vulkan-tools
  ```
  (Debian/Ubuntu: `libwayland-client0 libwayland-cursor0 libwayland-egl1 libdecor-0-0
  libx11-6 libxext6 libxcursor1 libxi6 libxrandr2 libxfixes3 libxkbcommon0 libvulkan1
  mesa-vulkan-drivers vulkan-tools`.)
- **WSL2 specifics (important):**
  - **Build/run from a Linux-native path** (e.g. `~/mana`), **not** a Windows-drive mount
    (`/mnt/c/...`) — zig's build cache can't do atomic renames on DrvFs and fails with
    `AccessDenied`.
  - The display comes from **WSLg** (`echo $WAYLAND_DISPLAY $DISPLAY` are set; `/mnt/wslg`
    exists). Let SDL auto-pick Wayland; don't force `SDL_VIDEODRIVER`.
  - Vulkan reaches your Windows GPU through Mesa's **`dzn`** driver (Vulkan-on-D3D12).
    Verify a device is visible: `vulkaninfo --summary`. If none appears, try
    `DZN_ENABLE=1 ./zig-out/bin/mana games/pacman --play`.
- **Troubleshooting the two failure points:**
  - `error.SdlInit` → the Wayland/X11 **client libs** are missing (first `dnf` line above).
  - `error.SdlCreateWindow` → the **Vulkan loader/ICD** is missing (second `dnf` line); the
    window is requested with `SDL_WINDOW_VULKAN`, so it can't be created without one.
- No GPU at all? Fall back to headless (the hash-printing run above) or the no-GPU preview
  below.

**Seeing a game without a GPU (CI / headless boxes):** a headless renderer can dump
frames you open in a browser — a single static frame (`--render-svg <file>`), a
filmstrip over N ticks (`--filmstrip <dir> --ticks <n>`), or the **textured-sprite
composite** as a PNG (`--render-play-frame <file.png> [--ticks N]`). This is a
regression/CI aid, not the intended way to judge how a game looks or feels — for that,
`--play` it.

```sh
mise x -- zig build -Denable-lua run -- games/pacman --filmstrip ./out/pacman --ticks 30
```

`--render-play-frame` is the headless mirror of `--play`'s pixels: it loads the scene,
packs the sprite atlas, advances **N deterministic ticks** (fixed dt, not wall-clock),
then composites the flat quads **and** the textured, direction-facing sprites through the
null backend's CPU rasterizer — which samples the atlas exactly as the Vulkan pipeline
does — and writes the RGBA readback to PNG. So a sprite bug (wrong frame, wrong facing,
flattened footprint) shows up in the PNG + CI, not only when a human plays a broken build.
Needs **no GPU**; a Lua-driven game still needs `-Denable-lua` for its scene handler to
spawn the sprited entities (as with the other headless modes). First run `mise run assets`
so the derived `.msf` sheets exist.

```sh
mise run assets   # generate the gitignored sprite sheets the sprites reference
mise x -- zig build -Denable-lua run -- games/pacman --render-play-frame ./out/pac.png --ticks 10
```
