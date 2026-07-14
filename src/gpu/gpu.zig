//! gpu — the renderer port. Defines the engine-owned GPU vocabulary (ADR 0010:
//! Texture, Buffer, Pipeline, CommandList over a `Device`) and selects a backend at
//! comptime via build options. This is the ONLY module permitted to import Vulkan
//! types; nothing above `gpu` may see them. `renderScene` is backend-agnostic — it
//! drives the selected `Device` through the port, so the same orchestration runs on
//! the null backend (the real, testable default) and the Vulkan backend. The Vulkan
//! backend is compiled only under `-Denable-vulkan`.

const std = @import("std");
const core = @import("core");
const build_options = @import("build_options");
const port = @import("port.zig");

const Allocator = std.mem.Allocator;

/// Plain-data quad the engine hands the port to draw (no Vulkan types).
pub const Quad = @import("types.zig").Quad;
/// The silhouette a `Quad` draws as (ADR 0030 shape addendum): `rect` (default) or
/// `circle`.
pub const Shape = @import("types.zig").Shape;
/// A textured, tinted sprite quad addressing a sub-rect of the bound atlas (ADR 0031).
pub const SpriteQuad = @import("types.zig").SpriteQuad;

// --- Port vocabulary (engine-owned, backend-free) --------------------------------
pub const TextureFormat = port.TextureFormat;
pub const TextureUsage = port.TextureUsage;
pub const BufferUsage = port.BufferUsage;
pub const TextureDesc = port.TextureDesc;
pub const BufferDesc = port.BufferDesc;
pub const Vertex = port.Vertex;
pub const TexturedVertex = port.TexturedVertex;
// Presentation-surface vocabulary (ADR 0012).
pub const SurfaceHandle = port.SurfaceHandle;
pub const PresentMode = port.PresentMode;
pub const AcquireStatus = port.AcquireStatus;
pub const SwapchainDesc = port.SwapchainDesc;

/// Available GPU backends, selected at comptime via build options.
pub const Backend = enum { null_backend, vulkan };

/// The backend compiled into this build, chosen at comptime from `-Denable-vulkan`.
pub const backend: Backend = if (build_options.enable_vulkan) .vulkan else .null_backend;

/// The concrete backend module implementing the port. Kept internal: the Vulkan
/// import (and its bindings) never enter a default build, and nothing above `gpu`
/// names a backend — callers use the port types below and `renderScene`.
const impl = if (build_options.enable_vulkan) @import("vulkan/backend.zig") else @import("null/backend.zig");

// --- Port resource types (each backend's concrete implementation) ----------------
/// GPU device: creates resources and submits recorded commands. Backend-owned.
pub const Device = impl.Device;
/// An offscreen colour target (the render destination). Backend-owned.
pub const Texture = impl.Texture;
/// A GPU buffer (vertex data or image readback). Backend-owned.
pub const Buffer = impl.Buffer;
/// The scene graphics pipeline. Backend-owned.
pub const Pipeline = impl.Pipeline;
/// The textured sprite pipeline (ADR 0031 §4): samples a bound atlas texture at
/// per-vertex UVs and multiplies by a tint. Sampled on the GPU (Vulkan) or by the null
/// backend's CPU nearest-neighbour rasterizer (headless). Backend-owned.
pub const TexturedPipeline = impl.TexturedPipeline;
/// Records rendering + copy commands for one submission. Backend-owned.
pub const CommandList = impl.CommandList;
/// A presentation swapchain over a window surface: acquire → render → present, with
/// resize/out-of-date recreation (ADR 0012). Built from a `SwapchainDesc`. Backend-owned.
pub const Swapchain = impl.Swapchain;
/// One acquired swapchain image plus its acquire status, for the frame being rendered.
/// `target` is the `Texture` to render into this frame. Backend-owned.
pub const Frame = impl.Frame;

/// Marker that the module is wired into the build graph.
pub const ready = core.ready;

/// Draw `quads` into a `width`×`height` offscreen colour target and read it back as
/// tightly-packed RGBA8 pixels (owned by `gpa`; caller frees). `clear` is the
/// background colour (RGBA, 0..1). This is the port's one operation, expressed
/// entirely through the vocabulary — create a `Texture`, `Buffer`s and a `Pipeline`,
/// record a `CommandList`, submit, read back — so it is identical on every backend.
/// Errors: `error.OutOfMemory` plus any backend device/allocation error.
pub fn renderScene(gpa: Allocator, width: u32, height: u32, quads: []const Quad, clear: [4]f32) ![]u8 {
    var dev = try Device.init(gpa);
    defer dev.deinit();

    var target = try dev.createTexture(.{
        .width = width,
        .height = height,
        .format = .rgba8_unorm,
        .usage = .{ .color_attachment = true, .transfer_src = true },
    });
    defer target.deinit(&dev);

    var readback = try dev.createBuffer(.{
        .size = @as(u64, width) * height * 4,
        .usage = .{ .transfer_dst = true },
    });
    defer readback.deinit(&dev);

    var pipeline = try dev.createScenePipeline(.rgba8_unorm);
    defer pipeline.deinit(&dev);

    // Vertex buffer: two triangles (6 vertices) per quad. Absent when there is
    // nothing to draw (the frame is then just a clear).
    const vertex_count: u32 = @intCast(quads.len * 6);
    var vbuf: ?Buffer = null;
    defer if (vbuf) |*b| b.deinit(&dev);
    if (vertex_count > 0) {
        const verts = try gpa.alloc(Vertex, vertex_count);
        defer gpa.free(verts);
        buildVertices(quads, verts);
        var b = try dev.createBuffer(.{
            .size = @as(u64, vertex_count) * @sizeOf(Vertex),
            .usage = .{ .vertex = true },
        });
        try b.write(&dev, std.mem.sliceAsBytes(verts));
        vbuf = b;
    }

    var cmd = try dev.beginCommands();
    defer cmd.deinit(&dev);
    cmd.beginRendering(&target, clear);
    if (vbuf) |*b| {
        cmd.bindPipeline(&pipeline);
        cmd.bindVertexBuffer(b);
        cmd.draw(vertex_count);
    }
    cmd.endRendering();
    cmd.copyTextureToBuffer(&target, &readback);
    try dev.submit(&cmd);

    return readback.read(&dev, gpa);
}

/// Draw `quads` into an already-acquired `target` through `pipeline`, clearing to
/// `clear` (RGBA, 0..1), and submit synchronously. This is the draw half of the
/// windowed present loop (ADR 0012 §6): `Swapchain.acquire` → `renderQuads(frame.target)`
/// → `Swapchain.present`. Unlike `renderScene` it renders into a caller-owned target
/// (a swapchain `Frame.target`) and does no readback, and it leaves `target` in exactly
/// the layout `present` expects (colour-attachment on the Vulkan backend, via the same
/// `beginRendering` UNDEFINED→colour transition the offscreen path uses) — so it reuses
/// the existing dynamic-rendering draw path rather than adding a new one. `gpa` backs a
/// temporary vertex upload freed before return (a reset per-frame arena in the loop).
/// Errors: `error.OutOfMemory` plus any backend device/allocation error.
pub fn renderQuads(gpa: Allocator, dev: *Device, pipeline: *Pipeline, target: *Texture, quads: []const Quad, clear: [4]f32) !void {
    // Two triangles (6 vertices) per quad; absent when there is nothing to draw (the
    // frame is then just a clear). Mirrors `renderScene`'s upload path.
    const vertex_count: u32 = @intCast(quads.len * 6);
    var vbuf: ?Buffer = null;
    defer if (vbuf) |*b| b.deinit(dev);
    if (vertex_count > 0) {
        const verts = try gpa.alloc(Vertex, vertex_count);
        defer gpa.free(verts);
        buildVertices(quads, verts);
        var b = try dev.createBuffer(.{
            .size = @as(u64, vertex_count) * @sizeOf(Vertex),
            .usage = .{ .vertex = true },
        });
        try b.write(dev, std.mem.sliceAsBytes(verts));
        vbuf = b;
    }

    var cmd = try dev.beginCommands();
    defer cmd.deinit(dev);
    cmd.beginRendering(target, clear);
    if (vbuf) |*b| {
        cmd.bindPipeline(pipeline);
        cmd.bindVertexBuffer(b);
        cmd.draw(vertex_count);
    }
    cmd.endRendering();
    try dev.submit(&cmd);
}

/// Draw one live frame into an already-acquired `target`: clear to `clear`, rasterize
/// the flat `quads` through `scene_pipeline`, then composite the textured `sprites` over
/// them through `sprite_pipeline` sampling `atlas` (ADR 0031 §4). One command list, one
/// submit, no readback — the sprite-aware analogue of `renderQuads` for the `--play`
/// present loop (ADR 0012 §6). Sprites are drawn *after* (on top of) the flat quads in
/// the same render pass so the alpha-blended sprite composites over the scene. If
/// `sprites` is empty or `atlas` is null the sprite pass is skipped (an all-flat frame,
/// identical to `renderQuads`). `target` is left colour-attachment-ready for `present`,
/// exactly like `renderQuads`. `gpa` backs two temporary vertex uploads freed before
/// return (a reset per-frame arena in the loop). Errors: `error.OutOfMemory` plus any
/// backend device/allocation error.
pub fn renderFrame(
    gpa: Allocator,
    dev: *Device,
    scene_pipeline: *Pipeline,
    sprite_pipeline: *TexturedPipeline,
    atlas: ?*Texture,
    target: *Texture,
    quads: []const Quad,
    sprites: []const SpriteQuad,
    clear: [4]f32,
) !void {
    const flat_count: u32 = @intCast(quads.len * 6);
    var vbuf: ?Buffer = null;
    defer if (vbuf) |*b| b.deinit(dev);
    if (flat_count > 0) {
        const verts = try gpa.alloc(Vertex, flat_count);
        defer gpa.free(verts);
        buildVertices(quads, verts);
        var b = try dev.createBuffer(.{ .size = @as(u64, flat_count) * @sizeOf(Vertex), .usage = .{ .vertex = true } });
        try b.write(dev, std.mem.sliceAsBytes(verts));
        vbuf = b;
    }

    // The sprite pass draws only when there is an atlas to sample and quads to place.
    const draw_sprites = atlas != null and sprites.len > 0;
    const sprite_count: u32 = if (draw_sprites) @intCast(sprites.len * 6) else 0;
    var sbuf: ?Buffer = null;
    defer if (sbuf) |*b| b.deinit(dev);
    if (sprite_count > 0) {
        const verts = try gpa.alloc(TexturedVertex, sprite_count);
        defer gpa.free(verts);
        buildTexturedVertices(sprites, verts);
        var b = try dev.createBuffer(.{ .size = @as(u64, sprite_count) * @sizeOf(TexturedVertex), .usage = .{ .vertex = true } });
        try b.write(dev, std.mem.sliceAsBytes(verts));
        sbuf = b;
    }

    var cmd = try dev.beginCommands();
    defer cmd.deinit(dev);
    cmd.beginRendering(target, clear);
    if (vbuf) |*b| {
        cmd.bindPipeline(scene_pipeline);
        cmd.bindVertexBuffer(b);
        cmd.draw(flat_count);
    }
    if (sbuf) |*b| {
        cmd.bindTexturedPipeline(sprite_pipeline);
        cmd.bindTexture(sprite_pipeline, atlas.?);
        cmd.bindVertexBuffer(b);
        cmd.draw(sprite_count);
    }
    cmd.endRendering();
    try dev.submit(&cmd);
}

/// Render one sprite-aware frame into an owned offscreen target and read it back as
/// tightly-packed RGBA8 (owned by `gpa`; caller frees) — the headless, no-window analogue
/// of the `--play` present loop's draw zone (issue #122). It composites the flat `quads`
/// then the textured `sprites` over them by calling the **same** `renderFrame` the live
/// loop uses (identical geometry, UV sub-rects and facing rotation), so a `projectSprites`
/// bug reproduces in the captured PNG. `atlas_pixels` is the CPU atlas (RGBA8,
/// `atlas_width*atlas_height*4` bytes) uploaded to a sampled texture; `atlas_width == 0`
/// means no atlas (the sprite pass is skipped). Deterministic and GPU-free on the null
/// backend, so a broken sprite is caught by CI, not by a user playing `--play`. Errors:
/// `error.OutOfMemory` plus any backend device/allocation error.
pub fn captureFrame(
    gpa: Allocator,
    width: u32,
    height: u32,
    quads: []const Quad,
    sprites: []const SpriteQuad,
    atlas_pixels: []const u8,
    atlas_width: u32,
    atlas_height: u32,
    clear: [4]f32,
) ![]u8 {
    var dev = try Device.init(gpa);
    defer dev.deinit();

    var target = try dev.createTexture(.{
        .width = width,
        .height = height,
        .format = .rgba8_unorm,
        .usage = .{ .color_attachment = true, .transfer_src = true },
    });
    defer target.deinit(&dev);
    var scene_pipeline = try dev.createScenePipeline(.rgba8_unorm);
    defer scene_pipeline.deinit(&dev);
    var sprite_pipeline = try dev.createTexturedPipeline(.rgba8_unorm);
    defer sprite_pipeline.deinit(&dev);

    // Upload the CPU atlas to a sampled texture (skipped for an empty atlas).
    var atlas_tex: ?Texture = null;
    defer if (atlas_tex) |*t| t.deinit(&dev);
    if (atlas_width > 0 and atlas_height > 0) {
        var t = try dev.createTexture(.{
            .width = atlas_width,
            .height = atlas_height,
            .format = .rgba8_unorm,
            .usage = .{ .transfer_dst = true, .sampled = true },
        });
        errdefer t.deinit(&dev);
        try dev.uploadTexture(&t, atlas_pixels);
        atlas_tex = t;
    }
    const atlas_ptr: ?*Texture = if (atlas_tex) |*t| t else null;

    // Draw the composite via the exact `--play` recording, then read the target back.
    try renderFrame(gpa, &dev, &scene_pipeline, &sprite_pipeline, atlas_ptr, &target, quads, sprites, clear);
    var readback = try dev.createBuffer(.{ .size = @as(u64, width) * height * 4, .usage = .{ .transfer_dst = true } });
    defer readback.deinit(&dev);
    var cmd = try dev.beginCommands();
    defer cmd.deinit(&dev);
    cmd.copyTextureToBuffer(&target, &readback);
    try dev.submit(&cmd);
    return readback.read(&dev, gpa);
}

/// Expand each quad into 6 vertices (two triangles) in the shared `Vertex` layout.
/// `out.len` must be `quads.len * 6`. Pure; the same geometry feeds every backend.
fn buildVertices(quads: []const Quad, out: []Vertex) void {
    for (quads, 0..) |q, i| {
        const x0 = q.center[0] - q.half[0];
        const x1 = q.center[0] + q.half[0];
        const y0 = q.center[1] - q.half[1];
        const y1 = q.center[1] + q.half[1];
        const c = q.color;
        const base = i * 6;
        out[base + 0] = .{ .x = x0, .y = y0, .r = c[0], .g = c[1], .b = c[2] };
        out[base + 1] = .{ .x = x1, .y = y0, .r = c[0], .g = c[1], .b = c[2] };
        out[base + 2] = .{ .x = x0, .y = y1, .r = c[0], .g = c[1], .b = c[2] };
        out[base + 3] = .{ .x = x0, .y = y1, .r = c[0], .g = c[1], .b = c[2] };
        out[base + 4] = .{ .x = x1, .y = y0, .r = c[0], .g = c[1], .b = c[2] };
        out[base + 5] = .{ .x = x1, .y = y1, .r = c[0], .g = c[1], .b = c[2] };
    }
}

/// Expand each sprite quad into 6 textured vertices (two triangles) in the shared
/// `TexturedVertex` layout: each corner carries the quad's tint and the frame's UV
/// (top-left `uv_min` → bottom-right `uv_max`, matching the atlas's top-to-bottom row
/// order), and its position is rotated about the quad centre by `angle` so a directional
/// sprite faces its travel direction (UVs stay unrotated). `out.len` must be
/// `quads.len * 6`. Pure; the same geometry feeds every backend. Winding matches
/// `buildVertices` (TL, TR, BL, BL, TR, BR).
///
/// The rotation is done in ISOTROPIC (square, pixel-space) coordinates — a unit corner
/// `(±1, ±1)` is rotated, then scaled per-axis by the NDC half-extents `(hx, hy)`. Since
/// `hx = half_px/half_w` and `hy = half_px/half_h`, the on-screen quad is `half_px` square
/// regardless of viewport aspect; scaling AFTER the rotation keeps it square. Rotating the
/// already-anisotropic NDC offsets instead (the old bug, issue #121) let a 90° turn swap
/// `hx`↔`hy`, squashing Pac into a flat sideways oval on a non-square `--play` window.
fn buildTexturedVertices(quads: []const SpriteQuad, out: []TexturedVertex) void {
    for (quads, 0..) |q, i| {
        const cos = @cos(q.angle);
        const sin = @sin(q.angle);
        const cx = q.center[0];
        const cy = q.center[1];
        const hx = q.half[0];
        const hy = q.half[1];
        // A unit corner (sx, sy) ∈ {-1,+1}²: rotate it in square pixel space, THEN scale
        // by the NDC half-extents. `hx`/`hy` are the common factor of x/y, never mixed
        // into the other axis's rotation term — so a non-square viewport can't squash it.
        const corner = struct {
            fn at(sx: f32, sy: f32, c: f32, s: f32, ox: f32, oy: f32, ehx: f32, ehy: f32, u: f32, v: f32, tint: [3]f32) TexturedVertex {
                return .{
                    .x = ox + ehx * (sx * c - sy * s),
                    .y = oy + ehy * (sx * s + sy * c),
                    .u = u,
                    .v = v,
                    .r = tint[0],
                    .g = tint[1],
                    .b = tint[2],
                };
            }
        }.at;
        const umin = q.uv_min[0];
        const vmin = q.uv_min[1];
        const umax = q.uv_max[0];
        const vmax = q.uv_max[1];
        const base = i * 6;
        out[base + 0] = corner(-1, -1, cos, sin, cx, cy, hx, hy, umin, vmin, q.tint); // TL
        out[base + 1] = corner(1, -1, cos, sin, cx, cy, hx, hy, umax, vmin, q.tint); // TR
        out[base + 2] = corner(-1, 1, cos, sin, cx, cy, hx, hy, umin, vmax, q.tint); // BL
        out[base + 3] = corner(-1, 1, cos, sin, cx, cy, hx, hy, umin, vmax, q.tint); // BL
        out[base + 4] = corner(1, -1, cos, sin, cx, cy, hx, hy, umax, vmin, q.tint); // TR
        out[base + 5] = corner(1, 1, cos, sin, cx, cy, hx, hy, umax, vmax, q.tint); // BR
    }
}

test "buildTexturedVertices: a 90° facing turn preserves the quad's NDC footprint (no oval on a non-square viewport)" {
    // Issue #121: on a wide `--play` window the sprite's NDC half-extents are anisotropic
    // (hx != hy). A correct facing rotation keeps the on-screen quad square, so its NDC
    // bounding box stays hx wide × hy tall at any angle — only the TEXTURE turns. The old
    // code rotated the NDC offsets directly, swapping hx↔hy at 90° and squashing it.
    const hx: f32 = 0.4; // wide (world unit spans more screen-x than screen-y here)
    const hy: f32 = 0.1;
    const q = [_]SpriteQuad{.{
        .center = .{ 0, 0 },
        .half = .{ hx, hy },
        .uv_min = .{ 0, 0 },
        .uv_max = .{ 1, 1 },
        .angle = std.math.pi / 2.0, // facing up/down: the case that used to collapse
    }};
    var v: [6]TexturedVertex = undefined;
    buildTexturedVertices(&q, &v);

    // NDC bounding box is unchanged from the axis-aligned quad: ±hx in x, ±hy in y.
    var max_x: f32 = 0;
    var max_y: f32 = 0;
    for (v) |vert| {
        max_x = @max(max_x, @abs(vert.x));
        max_y = @max(max_y, @abs(vert.y));
    }
    try std.testing.expectApproxEqAbs(hx, max_x, 1e-6); // NOT squashed to hy
    try std.testing.expectApproxEqAbs(hy, max_y, 1e-6); // NOT stretched to hx
    // The texture really turned 90°: the frame's top-left texel (uv 0,0 → vertex 0) now
    // sits at the quad's top-right corner (+hx, -hy) rather than the top-left (-hx, -hy).
    try std.testing.expectApproxEqAbs(hx, v[0].x, 1e-6);
    try std.testing.expectApproxEqAbs(-hy, v[0].y, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), v[0].u, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), v[0].v, 1e-6);
}

test "gpu backend matches the build flag" {
    const expected: Backend = if (build_options.enable_vulkan) .vulkan else .null_backend;
    try std.testing.expectEqual(expected, backend);
}

test "renderScene: empty scene yields a fully-cleared image" {
    const clear = [4]f32{ 1, 0, 0, 1 }; // opaque red
    const pixels = try renderScene(std.testing.allocator, 4, 4, &.{}, clear);
    defer std.testing.allocator.free(pixels);
    try std.testing.expectEqual(@as(usize, 4 * 4 * 4), pixels.len);
    // Backend-agnostic call; on the null backend (the default test path) the clear
    // colour is written exactly, so assert it there.
    if (backend == .null_backend) {
        var i: usize = 0;
        while (i < pixels.len) : (i += 4) {
            try std.testing.expectEqual(@as(u8, 255), pixels[i + 0]);
            try std.testing.expectEqual(@as(u8, 0), pixels[i + 1]);
        }
    }
}

test "renderQuads: draws into an acquired swapchain frame, then presents it" {
    // Exercises the windowed loop's render half (acquire → renderQuads → present) on the
    // null backend — the only backend headless CI can run — so the exact draw path the
    // `--play` loop uses is covered without a GPU. Skipped on any other backend: this
    // drives `createSwapchain` with a NULL surface handle, which the null backend accepts
    // (headless has no OS window) but the Vulkan backend rejects (`error.NoSurfaceHandle`),
    // and its real present path needs a display+GPU anyway (a manual acceptance step).
    if (backend != .null_backend) return error.SkipZigTest;

    var dev = try Device.init(std.testing.allocator);
    defer dev.deinit();

    var sc = try dev.createSwapchain(.{ .surface = .{}, .width = 8, .height = 8, .format = .rgba8_unorm, .present_mode = .fifo });
    defer sc.deinit(&dev);
    var pipeline = try dev.createScenePipeline(.rgba8_unorm);
    defer pipeline.deinit(&dev);

    const frame = try sc.acquire(&dev);
    // One red quad covering the top-left NDC quadrant over a black clear.
    const quads = [_]Quad{.{ .center = .{ -0.5, -0.5 }, .half = .{ 0.5, 0.5 }, .color = .{ 1, 0, 0 } }};
    try renderQuads(std.testing.allocator, &dev, &pipeline, frame.target, &quads, .{ 0, 0, 0, 1 });
    _ = try sc.present(&dev, frame);

    if (backend == .null_backend) {
        // Top-left pixel lands inside the quad → red; bottom-right outside → clear black.
        try std.testing.expectEqual(@as(u8, 255), sc.presented[0]); // (0,0) R
        const last = (7 * 8 + 7) * 4;
        try std.testing.expectEqual(@as(u8, 0), sc.presented[last + 0]); // (7,7) R stayed clear
        try std.testing.expectEqual(@as(u8, 255), sc.presented[last + 3]); // (7,7) A
    }
}

test "renderFrame: composites a flat quad, then a textured sprite over it" {
    // Exercises the sprite-aware present-loop draw path (clear → flat quads → textured
    // sprites) on the null backend — the backend headless CI can run. The null backend
    // really samples the bound atlas (nearest-neighbour) and alpha-blends, so the sprite
    // pass is observable as the sampled, tinted texel compositing over the flat quad.
    var dev = try Device.init(std.testing.allocator);
    defer dev.deinit();
    var target = try dev.createTexture(.{ .width = 8, .height = 8, .format = .rgba8_unorm, .usage = .{ .color_attachment = true, .transfer_src = true } });
    defer target.deinit(&dev);
    var scene = try dev.createScenePipeline(.rgba8_unorm);
    defer scene.deinit(&dev);
    var sprite = try dev.createTexturedPipeline(.rgba8_unorm);
    defer sprite.deinit(&dev);
    // An opaque-white 2x2 atlas: the sprite's red tint multiplies it → red where drawn.
    var atlas = try dev.createTexture(.{ .width = 2, .height = 2, .format = .rgba8_unorm, .usage = .{ .transfer_dst = true, .sampled = true } });
    defer atlas.deinit(&dev);
    try dev.uploadTexture(&atlas, &(.{255} ** (2 * 2 * 4)));

    // A blue flat quad over the whole frame, then a red-tinted sprite over the top-left quadrant.
    const quads = [_]Quad{.{ .center = .{ 0, 0 }, .half = .{ 1, 1 }, .color = .{ 0, 0, 1 } }};
    const sprites = [_]SpriteQuad{.{ .center = .{ -0.5, -0.5 }, .half = .{ 0.5, 0.5 }, .uv_min = .{ 0, 0 }, .uv_max = .{ 1, 1 }, .tint = .{ 1, 0, 0 } }};
    try renderFrame(std.testing.allocator, &dev, &scene, &sprite, &atlas, &target, &quads, &sprites, .{ 0, 0, 0, 1 });

    if (backend == .null_backend) {
        // (0,0) is under the sprite: the sampled white texel × red tint (opaque) composited
        // over the blue flat quad → red.
        try std.testing.expectEqual(@as(u8, 255), target.pixels[0]); // R
        try std.testing.expectEqual(@as(u8, 0), target.pixels[2]); // B (red tint has none)
        // (7,7) is outside the sprite: only the blue flat quad shows through.
        const last = (7 * 8 + 7) * 4;
        try std.testing.expectEqual(@as(u8, 0), target.pixels[last + 0]); // R
        try std.testing.expectEqual(@as(u8, 255), target.pixels[last + 2]); // B
    }
}

test {
    _ = port;
    if (backend == .null_backend) _ = impl;
}
