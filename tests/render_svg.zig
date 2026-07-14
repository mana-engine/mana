//! Render-golden test (ADR 0029): a text-diffable visual-regression net, additive to
//! and independent from `tests/determinism.zig`'s state-hash golden. That hash catches
//! *simulation* drift; this catches *layout* drift (a maze row typo, a scale change) —
//! neither subsumes the other. Loads a real game package's scene file directly (not
//! through the manifest), projects it, emits SVG, and asserts byte-equality against a
//! checked-in golden under `tests/fixtures/`. Deliberately bypasses `game.zon`/
//! `checkScriptApi` so these tests need no `-Denable-lua` build: rendering the entry
//! scene never executes a package's script (mirrors `runRenderSvg`'s own load path,
//! which also never ticks or loads a script).

const std = @import("std");
const engine = @import("engine");

/// Known-good goldens, embedded at compile time so the on-disk fixture is locked in.
/// Regenerate via `MANA_UPDATE_GOLDENS=1` (see `writeGolden` below) as a deliberate,
/// reviewed step — the pre-commit hook blocks casual edits to `tests/fixtures/`.
const pacman_golden: []const u8 = @embedFile("fixtures/render_pacman_maze.svg");
const snake_golden: []const u8 = @embedFile("fixtures/render_snake_board.svg");

/// Render `scene_path` (relative to the repo root, the cwd `zig build test` runs
/// under) to SVG at a fixed 512x512 view through `scale` orthographic (ADR 0014).
/// Caller owns the returned bytes.
fn renderScene(gpa: std.mem.Allocator, io: std.Io, scene_path: []const u8, scale: f32) ![]u8 {
    var world = try engine.scene.loadWorldFromFile(gpa, io, std.Io.Dir.cwd(), scene_path);
    defer world.deinit();

    const view: engine.render.View = .{ .width = 512, .height = 512, .projection = .{ .orthographic = .{ .scale = scale } } };
    const quads = try engine.render.project(gpa, &world, view, &engine.render.default_palette, null);
    defer gpa.free(quads);
    return engine.render_svg.toSvg(gpa, quads, view, engine.render_svg.default_background);
}

test "render golden: the Pac-Man maze scene renders to the checked-in SVG" {
    const gpa = std.testing.allocator;
    const svg = try renderScene(gpa, std.testing.io, "games/pacman/scenes/maze.zon", 24);
    defer gpa.free(svg);
    try std.testing.expectEqualStrings(pacman_golden, svg);
}

test "render golden: the Snake board scene renders to the checked-in SVG" {
    const gpa = std.testing.allocator;
    const svg = try renderScene(gpa, std.testing.io, "games/snake/scenes/board.zon", 40);
    defer gpa.free(svg);
    try std.testing.expectEqualStrings(snake_golden, svg);
}

test "render golden: rendering the same scene twice is byte-identical (determinism)" {
    const gpa = std.testing.allocator;
    const a = try renderScene(gpa, std.testing.io, "games/pacman/scenes/maze.zon", 24);
    defer gpa.free(a);
    const b = try renderScene(gpa, std.testing.io, "games/pacman/scenes/maze.zon", 24);
    defer gpa.free(b);
    try std.testing.expectEqualStrings(a, b);
}
