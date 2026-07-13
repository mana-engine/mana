#!/usr/bin/env bash
# Local dev helper: run / see / test the mana games headlessly.
# All game rules live in Lua, so every mode needs -Denable-lua (mise run run does NOT set it).
#
#   ./scripts/games.sh test               # all unit + acceptance-scenario tests (both games)
#   ./scripts/games.sh scenarios pacman   # run each acceptance scenario for one game, one by one
#   ./scripts/games.sh scenarios snake
#   ./scripts/games.sh film pacman        # render a filmstrip (ticks the sim → live entities) — BEST way to SEE a game
#   ./scripts/games.sh film snake
#   ./scripts/games.sh svg pacman         # single STATIC frame (no script tick): good for the pacman maze...
#   ./scripts/games.sh svg snake          # ...but snake is empty this way (its whole board is script-spawned — use `film`)
#   ./scripts/games.sh play pacman        # live keyboard-playable window (needs SDL3 + Vulkan; see note below)
#
# Output SVGs go to $OUT (default /tmp/mana-games). Frame count via TICKS (default 30).
# Open an SVG with your browser, e.g.:  explorer.exe "$(wslpath -w /tmp/mana-games/pacman.svg)"
set -euo pipefail
cd "$(dirname "$0")/.."

ZB=(mise x -- zig build -Denable-lua)
mode="${1:-help}"
game="${2:-pacman}"
out="${OUT:-/tmp/mana-games}"
ticks="${TICKS:-30}"
mkdir -p "$out"

case "$mode" in
  test)
    "${ZB[@]}" test ;;
  scenarios)
    for s in games/"$game"/scenarios/*.zon; do
      echo "── $s ──"
      "${ZB[@]}" run -- games/"$game" --scenario "$s"
    done ;;
  film)
    "${ZB[@]}" run -- games/"$game" --filmstrip "$out/$game-film" --ticks "$ticks"
    echo "→ frames in $out/$game-film/  (open frame_0000.svg … in a browser)" ;;
  svg)
    "${ZB[@]}" run -- games/"$game" --render-svg "$out/$game.svg"
    echo "→ $out/$game.svg" ;;
  play)
    # Live windowed loop. Supervised deps: needs SDL3 installed + a Vulkan-capable display
    # (WSLg on WSL2). Verified on native Windows; may need `dnf install SDL3-devel` here first.
    mise x -- zig build -Denable-lua -Denable-sdl3 -Denable-vulkan run -- games/"$game" --play ;;
  *)
    echo "usage: $0 {test|scenarios|film|svg|play} [pacman|snake]"
    echo "  test       all unit + acceptance-scenario tests"
    echo "  scenarios  run each acceptance scenario for one game"
    echo "  film       filmstrip SVGs over TICKS ticks (best visual; both games)"
    echo "  svg        single static frame (pacman maze only; snake renders empty)"
    echo "  play       live keyboard window (needs SDL3 + Vulkan)"
    exit 1 ;;
esac
