//! render_ui — the UI-tree → GPU draw-list bridge (issue #133; ADR 0034 §8).
//!
//! The `ui` module is the pure interpreter (parse → layout → hit-test → one-way binding);
//! it deliberately owns no font atlas and emits no glyphs (ADR 0034 §8 deferred exactly
//! that to this slice). This engine-side bridge closes the loop: it walks a laid-out
//! `ui.Screen`, resolves each widget's displayed value through the `ui.Host` seam, and
//! emits the two draw lists the existing `gpu` compositor already knows how to rasterize —
//! flat `gpu.Quad`s for `panel` backgrounds and `gpu.SpriteQuad`s for `label` text, the
//! LATTER produced by REUSING `text.layout`/`text.projectText` and the embedded font atlas
//! (#131). Nothing new reaches the GPU: `gpu.captureFrame`/`renderFrame` composite a UI
//! draw list byte-for-byte the way they composite sprites, so a HUD renders headlessly and
//! a layout bug reproduces in a captured PNG.
//!
//! It lives in `engine`, not `ui`, for the same reason `render.zig` does: the glyph atlas
//! and text layout (`text.zig`) are engine-tier, so the tree→text→draw-list composition
//! belongs where text does. `ui` stays a `core + gpu + platform` port module with no
//! font/atlas dependency (ADR 0034 §5). **Cosmetic and hash-excluded** (ADR 0034 §4): this
//! reads gameplay state only one-way through `host` and writes no `World` column, so — like
//! `Appearance`/`Sprite` — it can never perturb `World.stateHash`. Pure and GPU-free on the
//! null backend, so panel placement and glyph ink are asserted without a window.

const std = @import("std");
const gpu = @import("gpu");
const ui = @import("ui");
const text = @import("text.zig");
const sprite = @import("sprite.zig");
const World = @import("world.zig").World;

const Allocator = std.mem.Allocator;

/// The GPU draw list a `ui.Screen` projects to: flat `rects` (panel backgrounds) drawn
/// first, then `glyphs` (label text) composited over them — the order `gpu.captureFrame`
/// draws its `quads` then `sprites` arguments. Owns both slices; free with `deinit`.
pub const DrawList = struct {
    gpa: Allocator,
    /// Filled `panel` backgrounds, in NDC — pass as `captureFrame`'s `quads`.
    rects: []gpu.Quad,
    /// `label` glyphs sampling the font atlas, in NDC — pass as `captureFrame`'s `sprites`
    /// (with the font atlas as the bound atlas).
    glyphs: []gpu.SpriteQuad,

    /// Free both draw-list slices.
    pub fn deinit(self: *DrawList) void {
        self.gpa.free(self.rects);
        self.gpa.free(self.glyphs);
    }
};

/// Projection controls. `metrics` sizes glyph cells (defaults to the embedded 5x7 font);
/// `max_text_scale` caps the integer pixel scale a `label`'s rect height derives, so a
/// label given no explicit height (its rect fills the viewport) does not blow up to a
/// screen-filling glyph. A widget with an explicit `height` picks the largest integer
/// scale whose cell fits that height.
pub const Options = struct {
    metrics: text.Metrics = .{},
    max_text_scale: f32 = 8,
};

/// Project `screen` (filling a `view_w`×`view_h` framebuffer) into a `DrawList`: lay it
/// out, then for every widget emit a flat quad (`panel`) or a run of glyph quads (`label`,
/// its displayed value resolved through `host` — a bound scalar/string, else its static
/// `text`). `container`/`image` widgets emit nothing here (layout-only / a later slice).
/// `font` is the atlas `text.buildFontAtlas` produced; label glyphs sample it, so the same
/// atlas must be the one bound when the returned `glyphs` are drawn. Pure and deterministic
/// (no sim mutation, no I/O); caller owns the result (`deinit`). Errors: `error.OutOfMemory`.
pub fn project(
    gpa: Allocator,
    screen: *const ui.Screen,
    host: ?ui.Host,
    view_w: u32,
    view_h: u32,
    font: *const sprite.Atlas,
    opts: Options,
) Allocator.Error!DrawList {
    const viewport: ui.Rect = .{ .x = 0, .y = 0, .w = @floatFromInt(view_w), .h = @floatFromInt(view_h) };
    const placed = try ui.layout(gpa, screen, viewport);
    defer gpa.free(placed);

    var rects: std.ArrayList(gpu.Quad) = .empty;
    errdefer rects.deinit(gpa);
    var glyphs: std.ArrayList(gpu.SpriteQuad) = .empty;
    errdefer glyphs.deinit(gpa);

    for (placed) |p| {
        switch (p.widget.kind) {
            .panel => try rects.append(gpa, rectToQuad(p.rect, view_w, view_h, p.widget.color)),
            .label => try appendLabel(gpa, &glyphs, p, host, view_w, view_h, font, opts),
            .container, .image => {},
        }
    }

    return .{
        .gpa = gpa,
        .rects = try rects.toOwnedSlice(gpa),
        .glyphs = try glyphs.toOwnedSlice(gpa),
    };
}

/// Composite a `ui.Screen` over a fresh `clear` background into an RGBA8 frame, headlessly
/// (issue #133) — the display-only capture the anchor HUD slice needs. Projects the screen,
/// then draws the panel quads and glyph sprites through the SAME `gpu.captureFrame` sprites
/// use, binding the font atlas. Deterministic and GPU-free on the null backend. Caller owns
/// the returned pixels (`gpa.free`). Errors: `error.OutOfMemory` plus any backend error.
pub fn capture(
    gpa: Allocator,
    screen: *const ui.Screen,
    host: ?ui.Host,
    view_w: u32,
    view_h: u32,
    font: *const sprite.Atlas,
    clear: [4]f32,
    opts: Options,
) ![]u8 {
    var draw = try project(gpa, screen, host, view_w, view_h, font, opts);
    defer draw.deinit();
    return gpu.captureFrame(gpa, view_w, view_h, draw.rects, draw.glyphs, font.pixels, font.width, font.height, clear);
}

/// Convert a screen-pixel `rect` into an NDC `gpu.Quad` tinted `color` (RGB; alpha ignored —
/// the flat pipeline draws opaque). Mirrors `render.project`'s `screen_px/half - 1` mapping
/// so a UI quad lands exactly where a sprite quad at the same pixels would.
fn rectToQuad(rect: ui.Rect, view_w: u32, view_h: u32, color: [4]f32) gpu.Quad {
    const half_w = @as(f32, @floatFromInt(view_w)) / 2;
    const half_h = @as(f32, @floatFromInt(view_h)) / 2;
    const cx = rect.x + rect.w / 2;
    const cy = rect.y + rect.h / 2;
    return .{
        .center = .{ cx / half_w - 1, cy / half_h - 1 },
        .half = .{ (rect.w / 2) / half_w, (rect.h / 2) / half_h },
        .color = .{ color[0], color[1], color[2] },
    };
}

/// Resolve label `p`'s displayed string through `host`, lay it out at `p.rect`'s top-left
/// scaled to fit the rect's height, and append its glyph quads to `glyphs`. The value is the
/// `bind`ing when set and resolved, else the static `text` (`ui.boundValue`); a `.number`
/// is formatted into a small stack buffer. Errors: `error.OutOfMemory`.
fn appendLabel(
    gpa: Allocator,
    glyphs: *std.ArrayList(gpu.SpriteQuad),
    p: ui.Placed,
    host: ?ui.Host,
    view_w: u32,
    view_h: u32,
    font: *const sprite.Atlas,
    opts: Options,
) Allocator.Error!void {
    var buf: [32]u8 = undefined;
    const str = formatValue(ui.boundValue(p.widget, host), &buf);

    var lay = try text.layout(gpa, str, .{ .metrics = opts.metrics });
    defer lay.deinit();

    // Size the text to the label's rect height: the largest integer pixel scale whose cell
    // fits, clamped to `max_text_scale`, never below 1 (so a zero-height rect still draws).
    const fit = @floor(p.rect.h / opts.metrics.cell_h);
    const scale = std.math.clamp(fit, 1, opts.max_text_scale);

    const screen: text.Screen = .{
        .view_w = view_w,
        .view_h = view_h,
        .origin = .{ p.rect.x, p.rect.y },
        .scale = scale,
        .tint = .{ p.widget.color[0], p.widget.color[1], p.widget.color[2] },
    };
    const quads = try text.projectText(gpa, lay, font, screen);
    defer gpa.free(quads);
    try glyphs.appendSlice(gpa, quads);
}

/// Render a bound `Value` to a displayable string in `buf`: text as-is; a whole number as an
/// integer (`1200`), a fractional one to two decimals (`1.50`). A number too long for `buf`
/// (never, for a HUD scalar) falls back to a truncated form rather than erroring.
fn formatValue(v: ui.Value, buf: []u8) []const u8 {
    return switch (v) {
        .text => |t| t,
        .number => |n| blk: {
            if (@floor(n) == n and @abs(n) < 1e15) {
                break :blk std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(n))}) catch buf[0..0];
            }
            break :blk std.fmt.bufPrint(buf, "{d:.2}", .{n}) catch buf[0..0];
        },
    };
}

/// Build a `ui.Host` that resolves a bound label name to the value of the same-named data
/// component (ADR 0024) on the live `world` — the engine-side fill of the §5 `Host` seam
/// that lets a HUD display gameplay state without `ui` ever touching `World`. This glue is
/// **generic**: it knows no data-component name (invariant #6) — the key comes from the
/// game's HUD ZON `bind` (e.g. `"score"`), never from `src/`. A HUD scalar is a singleton
/// gameplay fact carried on ONE entity (the player's `score`/`lives`), so the seam returns
/// the value on the FIRST entity (dense-storage order, deterministic) that carries the
/// column; an unbound/undeclared name yields `null`, and `ui.boundValue` falls back to the
/// widget's static text. Read-only: it never writes `World`, so it cannot perturb the state
/// hash. `world` is borrowed for the returned host's lifetime.
pub fn worldHost(world: *World) ui.Host {
    return .{ .ctx = world, .vtable = &world_host_vtable };
}

const world_host_vtable: ui.Host.VTable = .{ .value = worldHostValue };

/// The `worldHost` vtable read: the first entity's value in the data column named `name`,
/// or `null` if no column is declared for `name` (or the column is empty). Deterministic —
/// dense storage order is stable within a tick.
fn worldHostValue(ctx: *anyopaque, name: []const u8) ?ui.Value {
    const world: *World = @ptrCast(@alignCast(ctx));
    const col = world.dataColumn(name) orelse return null;
    const set = &world.data.columns.items[col];
    const vals = set.slice();
    if (vals.len == 0) return null;
    return .{ .number = vals[0] };
}

// --- Tests ------------------------------------------------------------------------

const testing = std.testing;

/// A fake `ui.Host` over a fixed name→value table — the headless binding double (ADR 0034
/// §5), standing in for the engine's live-`Sim` fill.
const FakeHost = struct {
    score: f64 = 0,
    lives: f64 = 0,

    fn value(ctx: *anyopaque, name: []const u8) ?ui.Value {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, name, "score")) return .{ .number = self.score };
        if (std.mem.eql(u8, name, "lives")) return .{ .number = self.lives };
        return null;
    }
    const vtable: ui.Host.VTable = .{ .value = value };

    fn host(self: *FakeHost) ui.Host {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

test "render_ui: a panel projects to a flat NDC quad at its pixel footprint" {
    const gpa = testing.allocator;
    // A 200×100 panel filling a 200×100 viewport: center NDC (0,0), half NDC (1,1).
    const screen: ui.Screen = .{ .root = .{ .kind = .panel, .color = .{ 0.2, 0.4, 0.8, 1 } } };
    var draw = try project(gpa, &screen, null, 200, 100, undefined, .{});
    defer draw.deinit();

    try testing.expectEqual(@as(usize, 1), draw.rects.len);
    try testing.expectEqual(@as(usize, 0), draw.glyphs.len);
    try testing.expectApproxEqAbs(@as(f32, 0), draw.rects[0].center[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0), draw.rects[0].center[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), draw.rects[0].half[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.4), draw.rects[0].color[1], 1e-6);
}

test "render_ui: a label emits one glyph quad per visible character of its bound value" {
    const gpa = testing.allocator;
    var atlas = try text.buildFontAtlas(gpa);
    defer atlas.deinit();

    var fake: FakeHost = .{ .score = 1200 };
    // A label bound to `score` over a 3-cell-tall rect ⇒ "1200" = 4 visible glyphs.
    const children = [_]ui.Widget{
        .{ .kind = .label, .bind = "score", .text = "0", .height = 21, .width = 200 },
    };
    const screen: ui.Screen = .{ .root = .{ .kind = .container, .layout = .anchor, .children = &children } };
    var draw = try project(gpa, &screen, fake.host(), 256, 64, &atlas, .{});
    defer draw.deinit();

    try testing.expectEqual(@as(usize, 0), draw.rects.len); // container + label draw no panel
    try testing.expectEqual(@as(usize, 4), draw.glyphs.len); // "1200"
}

test "render_ui: an unresolved binding falls back to the widget's static text" {
    const gpa = testing.allocator;
    var atlas = try text.buildFontAtlas(gpa);
    defer atlas.deinit();

    var fake: FakeHost = .{};
    // `nope` is not a host binding ⇒ the static "HI" (2 glyphs) renders instead.
    const children = [_]ui.Widget{
        .{ .kind = .label, .bind = "nope", .text = "HI", .height = 14 },
    };
    const screen: ui.Screen = .{ .root = .{ .kind = .container, .children = &children } };
    var draw = try project(gpa, &screen, fake.host(), 128, 32, &atlas, .{});
    defer draw.deinit();
    try testing.expectEqual(@as(usize, 2), draw.glyphs.len);
}

test "render_ui: end-to-end headless capture composites a panel and text ink" {
    // The load-bearing proof (issue #133): a ZON UI tree → draw list → the SAME
    // `gpu.captureFrame` sprites use → the null backend paints the panel and alpha-blends
    // the glyph ink over it. A HUD is thus VISIBLE headlessly, no window.
    const gpa = testing.allocator;
    var atlas = try text.buildFontAtlas(gpa);
    defer atlas.deinit();

    const src =
        \\.{
        \\    .name = "hud",
        \\    .root = .{
        \\        .kind = .container,
        \\        .layout = .anchor,
        \\        .padding = 4,
        \\        .children = .{
        \\            .{ .kind = .panel, .anchor = .top_left, .width = 120, .height = 24, .color = .{ 0.1, 0.1, 0.5, 1 } },
        \\            .{ .kind = .label, .anchor = .top_left, .width = 120, .height = 21, .text = "SCORE 42", .color = .{ 1, 1, 1, 1 } },
        \\        },
        \\    },
        \\}
    ;
    const screen = try ui.parse(gpa, src);
    defer ui.free(gpa, screen);

    const view_w: u32 = 160;
    const view_h: u32 = 48;
    const pixels = capture(gpa, &screen, null, view_w, view_h, &atlas, .{ 0, 0, 0, 1 }, .{}) catch |e| {
        if (gpu.backend != .null_backend) return error.SkipZigTest; // no GPU device here
        return e;
    };
    defer gpa.free(pixels);

    // The panel painted its blue: sample inside its footprint (x∈4..124, y∈4..28) but below
    // the 21px-tall text band (rows 4..25), so the probe hits panel, not glyph ink.
    const panel_px = (@as(usize, 26) * view_w + 10) * 4;
    try testing.expect(pixels[panel_px + 2] > 100); // blue channel of the panel
    try testing.expect(pixels[panel_px + 0] < 100); // and not much red

    // Some glyph ink (near-white) landed inside the label band (rows 4..25).
    var lit: u32 = 0;
    var y: u32 = 4;
    while (y < 25) : (y += 1) {
        var x: u32 = 4;
        while (x < 140) : (x += 1) {
            const o = (@as(usize, y) * view_w + x) * 4;
            // White ink over blue panel ⇒ red channel rises well above the panel's ~0.1.
            if (pixels[o + 0] > 180) lit += 1;
        }
    }
    try testing.expect(lit > 0);

    // A far corner outside the HUD stays the black clear (no stray ink).
    const corner = (@as(usize, view_h - 1) * view_w + (view_w - 1)) * 4;
    try testing.expectEqual(@as(u8, 0), pixels[corner + 0]);
}

test "render_ui: worldHost resolves a bound name to a data component on the live world" {
    const gpa = testing.allocator;
    var world = World.init(gpa);
    defer world.deinit();

    // One entity carrying score=1200; the HUD reads it by the key its ZON declares.
    const player = try world.spawn();
    try world.setDataByName(player, "score", 1200);

    const host = worldHost(&world);
    // A bound label resolves through the host to the live value.
    const score_w: ui.Widget = .{ .kind = .label, .bind = "score", .text = "0" };
    try testing.expectEqual(@as(f64, 1200), ui.boundValue(&score_w, host).number);
    // An undeclared name falls back to the widget's static text — no genre key baked in.
    const lives_w: ui.Widget = .{ .kind = .label, .bind = "lives", .text = "3" };
    try testing.expectEqualStrings("3", ui.boundValue(&lives_w, host).text);
}

test "render_ui: formatValue renders whole and fractional numbers and text" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1200", formatValue(.{ .number = 1200 }, &buf));
    try testing.expectEqualStrings("3", formatValue(.{ .number = 3 }, &buf));
    try testing.expectEqualStrings("1.50", formatValue(.{ .number = 1.5 }, &buf));
    try testing.expectEqualStrings("LIVES", formatValue(.{ .text = "LIVES" }, &buf));
}
