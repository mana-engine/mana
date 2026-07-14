//! Headless HUD acceptance (issue #133; ADR 0034 §4/§8): loads the REAL
//! `games/pacman/hud.zon` — the game's data-bound score/lives readout, authored as content
//! — and composites it over a frame through the exact engine path the runner's
//! `--render-play-frame`/`--play` uses: merge the font glyph atlas into a scene sprite atlas
//! (so ONE bound texture carries game sprites AND label glyphs), fill the `ui.Host` seam
//! from a live `World`'s named data components (ADR 0024), and capture through the null
//! backend. Proves end-to-end, no window and no Lua, that (a) the shipped HUD content parses
//! and lays out, (b) its `bind`ings resolve to live gameplay state via the generic
//! `render_ui.worldHost` (no genre key in `src/`), and (c) both a game sprite ref and the
//! HUD glyphs coexist in the single merged atlas. Cosmetic: it writes no world state, so it
//! cannot perturb the determinism hash. Lives in `tests/` because it reads the game corpus
//! (`src/**` may not).
//!
//! `games/snake/hud.zon` (issue #177) gets the same treatment below, proving the identical
//! generic path composites a second game's differently-named bindings (`score`/`length`)
//! with zero genre knowledge added to `src/`.

const std = @import("std");
const engine = @import("engine");

const Io = std.Io;

test "hud: the shipped pacman HUD composites live score/lives over a merged scene atlas" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // The real content file — human-editable ZON, the source of truth.
    const src = try Io.Dir.cwd().readFileAllocOptions(io, "games/pacman/hud.zon", gpa, .unlimited, .of(u8), 0);
    defer gpa.free(src);
    const screen = try engine.ui.parse(gpa, src);
    defer engine.ui.free(gpa, screen);

    // A minimal scene atlas (one 2x2 sheet) standing in for the game's sprites, merged with
    // the font glyph atlas exactly as the runner does — the single-bound-atlas solution.
    var scene_atlas = try synthAtlas(gpa);
    defer scene_atlas.deinit();
    var font = try engine.text.buildFontAtlas(gpa);
    defer font.deinit();
    var merged = try engine.sprite.merge(gpa, &scene_atlas, &font);
    defer merged.deinit();
    // The game sprite ref survives the merge, so a scene sprite could still sample it.
    try std.testing.expect(merged.uv("scene.msf", 0) != null);

    // Live gameplay state on one entity, read one-way through the engine's generic host —
    // the HUD's `bind = "score"`/`"lives"` keys come from the content, not from src/.
    var world = engine.World.init(gpa);
    defer world.deinit();
    const player = try world.spawn();
    try world.setDataByName(player, "score", 110);
    try world.setDataByName(player, "lives", 2);
    const host = engine.render_ui.worldHost(&world);

    const view_w: u32 = 512;
    const view_h: u32 = 512;
    const pixels = engine.render_ui.capture(gpa, &screen, host, view_w, view_h, &merged, .{ 0, 0, 0, 1 }, .{}) catch |e| {
        if (engine.gpu.backend != .null_backend) return error.SkipZigTest; // no GPU device here
        return e;
    };
    defer gpa.free(pixels);

    // The HUD sits in the top band (rows 0..40 with the 12px pad + ~22px labels). Count lit
    // pixels there: the score/lives glyphs must leave visible ink over the black clear.
    var lit: u32 = 0;
    var y: u32 = 0;
    while (y < 40) : (y += 1) {
        var x: u32 = 0;
        while (x < view_w) : (x += 1) {
            const o = (@as(usize, y) * view_w + x) * 4;
            if (pixels[o + 0] > 120 or pixels[o + 1] > 120) lit += 1;
        }
    }
    try std.testing.expect(lit > 40); // several inked glyph texels, not a stray pixel

    // The rest of the frame (well below the HUD band) stays the black clear — the HUD does
    // not bleed across the whole frame.
    const mid = (@as(usize, 300) * view_w + 256) * 4;
    try std.testing.expectEqual(@as(u8, 0), pixels[mid + 0]);
}

test "hud: the shipped snake HUD composites live score/length over a merged scene atlas" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // The real content file — human-editable ZON, the source of truth.
    const src = try Io.Dir.cwd().readFileAllocOptions(io, "games/snake/hud.zon", gpa, .unlimited, .of(u8), 0);
    defer gpa.free(src);
    const screen = try engine.ui.parse(gpa, src);
    defer engine.ui.free(gpa, screen);

    var scene_atlas = try synthAtlas(gpa);
    defer scene_atlas.deinit();
    var font = try engine.text.buildFontAtlas(gpa);
    defer font.deinit();
    var merged = try engine.sprite.merge(gpa, &scene_atlas, &font);
    defer merged.deinit();

    // Live gameplay state on the head entity, read one-way through the engine's generic
    // host — the HUD's `bind = "score"`/`"length"` keys come from the content, not `src/`.
    var world = engine.World.init(gpa);
    defer world.deinit();
    const head = try world.spawn();
    try world.setDataByName(head, "score", 40);
    try world.setDataByName(head, "length", 5);
    const host = engine.render_ui.worldHost(&world);

    const view_w: u32 = 512;
    const view_h: u32 = 512;
    const pixels = engine.render_ui.capture(gpa, &screen, host, view_w, view_h, &merged, .{ 0, 0, 0, 1 }, .{}) catch |e| {
        if (engine.gpu.backend != .null_backend) return error.SkipZigTest; // no GPU device here
        return e;
    };
    defer gpa.free(pixels);

    // The HUD sits in the top band (rows 0..40 with the 12px pad + ~22px labels). Count lit
    // pixels there: the score/length glyphs must leave visible ink over the black clear.
    var lit: u32 = 0;
    var y: u32 = 0;
    while (y < 40) : (y += 1) {
        var x: u32 = 0;
        while (x < view_w) : (x += 1) {
            const o = (@as(usize, y) * view_w + x) * 4;
            if (pixels[o + 0] > 120 or pixels[o + 1] > 120) lit += 1;
        }
    }
    try std.testing.expect(lit > 40); // several inked glyph texels, not a stray pixel

    // The rest of the frame (well below the HUD band) stays the black clear — the HUD does
    // not bleed across the whole frame.
    const mid = (@as(usize, 300) * view_w + 256) * 4;
    try std.testing.expectEqual(@as(u8, 0), pixels[mid + 0]);
}

/// A tiny one-frame scene atlas (a solid 2x2 red sheet under `"scene.msf"`) — the game-sprite
/// half of the merge, built through the same `sprite.buildAtlas` the runner uses.
fn synthAtlas(gpa: std.mem.Allocator) !engine.sprite.Atlas {
    var frame: [2 * 2 * 4]u8 = undefined;
    var i: usize = 0;
    while (i < frame.len) : (i += 4) {
        frame[i + 0] = 200;
        frame[i + 1] = 0;
        frame[i + 2] = 0;
        frame[i + 3] = 255;
    }
    var store: engine.sprite.SheetStore = .{ .gpa = gpa };
    defer store.entries.deinit(gpa);
    try store.entries.append(gpa, .{
        .ref = "scene.msf",
        .sheet = .{ .width = 2, .height = 2, .frames = &.{&frame}, .clips = &.{} },
    });
    return engine.sprite.buildAtlas(gpa, &store);
}
