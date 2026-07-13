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

// --- Port vocabulary (engine-owned, backend-free) --------------------------------
pub const TextureFormat = port.TextureFormat;
pub const TextureUsage = port.TextureUsage;
pub const BufferUsage = port.BufferUsage;
pub const TextureDesc = port.TextureDesc;
pub const BufferDesc = port.BufferDesc;
pub const Vertex = port.Vertex;
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

test {
    _ = port;
    if (backend == .null_backend) _ = impl;
}
