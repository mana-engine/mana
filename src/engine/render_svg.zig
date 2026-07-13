//! Headless SVG render output (ADR 0029, ADR 0030 shape addendum): turns
//! `render.project`'s GPU-free quads into a text SVG document — a background rect
//! plus one shape element per quad, `<rect>` or `<ellipse>` per `gpu.Quad.shape`. No
//! rasterizer, no GPU, no window: this compiles unconditionally into `engine` (never
//! behind `-Denable-vulkan`), so a level is viewable on the DEFAULT build. Byte-stable
//! (fixed 2-decimal-place coordinates, draw order = the caller's slice order — which
//! `render.project` already returns far-to-near depth-sorted and index-tie-broken), so
//! it doubles as a text-diffable visual-regression golden alongside the state-hash
//! determinism golden (`tests/determinism.zig`) — that one catches simulation drift,
//! this one catches layout drift. Genre-neutral: it knows only the `gpu.Quad`/
//! `render.View` vocabulary the Vulkan backend already consumes, nothing maze/pac-
//! specific.

const std = @import("std");
const gpu = @import("gpu");
const render = @import("render.zig");

const Allocator = std.mem.Allocator;

/// Background colour behind the quads, RGB 0..1 — matches the gpu backend's default
/// offscreen clear colour (`runRender`'s `.{ 0.09, 0.10, 0.14, 1.0 }`) so an SVG and a
/// PNG render of the same scene read the same.
pub const default_background = [3]f32{ 0.09, 0.10, 0.14 };

/// Render `quads` (already projected into NDC space by `render.project` through
/// `view`) as an SVG document: a `view.width` x `view.height` canvas, a full-bleed
/// `background` rect, then one shape element per quad in `quads`' given order — a
/// `<rect>` for `.rect`-shaped quads, an `<ellipse>` for `.circle`-shaped ones
/// (ADR 0030 shape addendum) — the caller's responsibility to have depth-sorted them
/// (`project` already does).
///
/// Deterministic and byte-stable: every coordinate and colour channel is printed at
/// fixed 2-decimal-place precision, and quads are emitted in plain slice order — no
/// map/hash iteration anywhere in this function — so two calls with identical inputs
/// produce byte-identical output. Caller owns the returned bytes.
pub fn toSvg(gpa: Allocator, quads: []const gpu.Quad, view: render.View, background: [3]f32) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.print(
        gpa,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\" viewBox=\"0 0 {d} {d}\">\n",
        .{ view.width, view.height, view.width, view.height },
    );
    try appendRect(gpa, &out, 0, 0, @floatFromInt(view.width), @floatFromInt(view.height), background);

    const half_w: f32 = @as(f32, @floatFromInt(view.width)) / 2;
    const half_h: f32 = @as(f32, @floatFromInt(view.height)) / 2;
    for (quads) |q| {
        // Undo `project`'s NDC mapping (center = screen/half_extent - 1) back to pixels.
        const cx = (q.center[0] + 1) * half_w;
        const cy = (q.center[1] + 1) * half_h;
        const hw = q.half[0] * half_w;
        const hh = q.half[1] * half_h;
        switch (q.shape) {
            .rect => try appendRect(gpa, &out, cx - hw, cy - hh, hw * 2, hh * 2, q.color),
            .circle => try appendEllipse(gpa, &out, cx, cy, hw, hh, q.color),
        }
    }

    try out.appendSlice(gpa, "</svg>\n");
    return out.toOwnedSlice(gpa);
}

/// Append one `<rect>` element at fixed 2-decimal precision. `color` channels are
/// 0..1 floats, converted to 0..255 `rgb()` integers.
fn appendRect(gpa: Allocator, out: *std.ArrayList(u8), x: f32, y: f32, w: f32, h: f32, color: [3]f32) Allocator.Error!void {
    try out.print(
        gpa,
        "<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" fill=\"rgb({d},{d},{d})\"/>\n",
        .{ x, y, w, h, toChannel(color[0]), toChannel(color[1]), toChannel(color[2]) },
    );
}

/// Append one `<ellipse>` element at fixed 2-decimal precision, centred at `cx, cy`
/// with radii `rx, ry` — a `.circle`-shaped quad's silhouette (ADR 0030 shape
/// addendum), inscribed in the same bounding box `appendRect` would fill with a
/// square. `color` channels are 0..1 floats, converted to 0..255 `rgb()` integers.
fn appendEllipse(gpa: Allocator, out: *std.ArrayList(u8), cx: f32, cy: f32, rx: f32, ry: f32, color: [3]f32) Allocator.Error!void {
    try out.print(
        gpa,
        "<ellipse cx=\"{d:.2}\" cy=\"{d:.2}\" rx=\"{d:.2}\" ry=\"{d:.2}\" fill=\"rgb({d},{d},{d})\"/>\n",
        .{ cx, cy, rx, ry, toChannel(color[0]), toChannel(color[1]), toChannel(color[2]) },
    );
}

/// Convert a 0..1 colour channel to a clamped 0..255 integer.
fn toChannel(c: f32) u8 {
    const clamped = std.math.clamp(c, 0, 1);
    return @intFromFloat(@round(clamped * 255));
}

const testing = std.testing;

test "toSvg: emits a background rect and one rect per quad, at expected pixel coords" {
    const quads = [_]gpu.Quad{
        .{ .center = .{ 0, 0 }, .half = .{ 0.25, 0.25 }, .color = .{ 1, 0, 0 } }, // NDC centre
        .{ .center = .{ 0.5, -0.5 }, .half = .{ 0.125, 0.125 }, .color = .{ 0, 1, 0 } },
    };
    const view: render.View = .{ .width = 256, .height = 256 };
    const svg = try toSvg(testing.allocator, &quads, view, .{ 0, 0, 0 });
    defer testing.allocator.free(svg);

    // Background: full-canvas black rect first.
    try testing.expect(std.mem.indexOf(u8, svg, "<rect x=\"0.00\" y=\"0.00\" width=\"256.00\" height=\"256.00\" fill=\"rgb(0,0,0)\"/>") != null);
    // Quad 1: centre (0,0) NDC -> pixel (128,128); half 0.25 NDC -> 32px half-extent -> 64x64 box at (96,96).
    try testing.expect(std.mem.indexOf(u8, svg, "<rect x=\"96.00\" y=\"96.00\" width=\"64.00\" height=\"64.00\" fill=\"rgb(255,0,0)\"/>") != null);
    // Quad 2: centre (0.5,-0.5) NDC -> pixel (192,64); half 0.125 NDC -> 16px half-extent -> 32x32 box at (176,48).
    try testing.expect(std.mem.indexOf(u8, svg, "<rect x=\"176.00\" y=\"48.00\" width=\"32.00\" height=\"32.00\" fill=\"rgb(0,255,0)\"/>") != null);

    // Draw order: quad 1's rect appears before quad 2's (caller's slice order).
    const pos_red = std.mem.indexOf(u8, svg, "rgb(255,0,0)").?;
    const pos_green = std.mem.indexOf(u8, svg, "rgb(0,255,0)").?;
    try testing.expect(pos_red < pos_green);
}

test "toSvg: deterministic — two calls on the same inputs are byte-identical" {
    const quads = [_]gpu.Quad{
        .{ .center = .{ 0.1, 0.2 }, .half = .{ 0.05, 0.05 }, .color = .{ 0.4, 0.5, 0.6 } },
    };
    const view: render.View = .{ .width = 128, .height = 128 };
    const a = try toSvg(testing.allocator, &quads, view, default_background);
    defer testing.allocator.free(a);
    const b = try toSvg(testing.allocator, &quads, view, default_background);
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(u8, a, b);
}

test "toSvg: an empty quad list still emits a valid document with just the background" {
    const view: render.View = .{ .width = 64, .height = 32 };
    const svg = try toSvg(testing.allocator, &.{}, view, .{ 1, 1, 1 });
    defer testing.allocator.free(svg);
    try testing.expect(std.mem.indexOf(u8, svg, "width=\"64\" height=\"32\"") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "fill=\"rgb(255,255,255)\"") != null);
    try testing.expect(std.mem.endsWith(u8, svg, "</svg>\n"));
}

test "toSvg: a circle-shaped quad emits an ellipse, not a rect" {
    const quads = [_]gpu.Quad{
        .{ .center = .{ 0, 0 }, .half = .{ 0.25, 0.25 }, .color = .{ 1, 0, 0 }, .shape = .circle },
    };
    const view: render.View = .{ .width = 256, .height = 256 };
    const svg = try toSvg(testing.allocator, &quads, view, .{ 0, 0, 0 });
    defer testing.allocator.free(svg);

    // NDC centre (0,0) -> pixel (128,128); half 0.25 NDC -> 32px radius.
    try testing.expect(std.mem.indexOf(u8, svg, "<ellipse cx=\"128.00\" cy=\"128.00\" rx=\"32.00\" ry=\"32.00\" fill=\"rgb(255,0,0)\"/>") != null);
    // No rect for this quad (only the background rect, which is 256x256).
    try testing.expect(std.mem.indexOf(u8, svg, "width=\"64.00\"") == null);
}

test "toSvg: colour channels round to the nearest 0..255 integer and clamp" {
    const quads = [_]gpu.Quad{
        .{ .center = .{ 0, 0 }, .half = .{ 0.1, 0.1 }, .color = .{ 1.5, -0.5, 0.5 } }, // out-of-range on purpose
    };
    const view: render.View = .{ .width = 100, .height = 100 };
    const svg = try toSvg(testing.allocator, &quads, view, .{ 0, 0, 0 });
    defer testing.allocator.free(svg);
    // 1.5 clamps to 1 -> 255; -0.5 clamps to 0 -> 0; 0.5 -> 128 (round(127.5) == 128).
    try testing.expect(std.mem.indexOf(u8, svg, "fill=\"rgb(255,0,128)\"") != null);
}
