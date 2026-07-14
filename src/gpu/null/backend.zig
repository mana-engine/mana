//! Null gpu backend — the default, GPU-free adapter and the renderer's real test
//! double (CLAUDE.md: "the null GPU backend is the only test double — a real
//! adapter"). It implements the exact same `Device` surface as the Vulkan backend
//! (ADR 0010) entirely on the CPU: a `Texture` is a host pixel buffer, a `Buffer`
//! is host bytes, and a `CommandList` records immediately — `beginRendering` clears
//! the target, `draw` software-rasterizes the bound vertices, and
//! `copyTextureToBuffer` memcpys pixels back. No Vulkan, no OS GPU calls, so it runs
//! in every headless build and in CI.
//!
//! The rasterizer fills axis-aligned quads (the only geometry the scene pipeline
//! ever emits — two triangles per quad from `renderScene`'s vertex builder). It is
//! deliberately not a general triangle rasterizer: the port draws quads, so the test
//! double draws quads. A richer renderer that needs more would grow both backends
//! together, under a new ADR.

const std = @import("std");
const port = @import("../port.zig");
const Allocator = std.mem.Allocator;

/// An offscreen colour target backed by a host RGBA8 pixel buffer owned by `gpa`.
pub const Texture = struct {
    width: u32,
    height: u32,
    /// Tightly-packed RGBA8, `width*height*4` bytes, owned by the creating device.
    pixels: []u8,

    /// Release the pixel buffer. `dev` supplies the owning allocator.
    pub fn deinit(self: *Texture, dev: *Device) void {
        dev.gpa.free(self.pixels);
    }
};

/// A host-visible byte buffer; the CPU analogue of a mapped GPU buffer.
pub const Buffer = struct {
    /// Backing storage, `BufferDesc.size` bytes, owned by the creating device.
    bytes: []u8,

    /// Release the backing storage. `dev` supplies the owning allocator.
    pub fn deinit(self: *Buffer, dev: *Device) void {
        dev.gpa.free(self.bytes);
    }

    /// Copy `data` into the buffer from offset 0. `data.len` must fit; caller owns
    /// `data`. `dev` is unused (host memory) but kept for surface parity. Never fails
    /// on the null backend; `!void` matches the Vulkan backend's fallible map.
    pub fn write(self: *Buffer, dev: *Device, data: []const u8) !void {
        _ = dev;
        @memcpy(self.bytes[0..data.len], data);
    }

    /// Return a `gpa`-owned copy of the buffer's contents (the read-back image).
    /// `dev` is unused here but kept for surface parity with the Vulkan backend,
    /// which needs the device to map memory. Errors: `error.OutOfMemory`.
    pub fn read(self: *const Buffer, dev: *Device, gpa: Allocator) ![]u8 {
        _ = dev;
        return gpa.dupe(u8, self.bytes);
    }
};

/// The scene pipeline. The null backend needs no pipeline state — the rasterizer is
/// fixed-function — so this is an empty handle present only for surface parity.
pub const Pipeline = struct {
    /// No-op release; present for surface parity with the Vulkan backend.
    pub fn deinit(self: *Pipeline, dev: *Device) void {
        _ = self;
        _ = dev;
    }
};

/// The textured sprite pipeline (ADR 0031 §4). Like `Pipeline`, an empty handle: the
/// null rasterizer is fixed-function (it samples the bound atlas per fragment; see
/// `CommandList.drawTextured`), so no pipeline state is needed. Present for surface
/// parity with the Vulkan backend's textured pipeline.
pub const TexturedPipeline = struct {
    /// No-op release; present for surface parity with the Vulkan backend.
    pub fn deinit(self: *TexturedPipeline, dev: *Device) void {
        _ = self;
        _ = dev;
    }
};

/// Records rendering work. The null backend is immediate-mode: each call mutates the
/// bound target's pixels right away, so `submit` has nothing left to flush.
pub const CommandList = struct {
    target: ?*Texture = null,
    vertices: []const u8 = &.{},
    /// Whether the bound pipeline is the textured sprite pipeline (ADR 0031): when set,
    /// `draw` interprets `vertices` as `port.TexturedVertex` and samples the bound atlas.
    /// `bindPipeline` (flat) clears it; `bindTexturedPipeline` sets it.
    textured: bool = false,
    /// The atlas the textured pipeline samples, bound by `bindTexture` (null until then).
    /// A textured `draw` samples it nearest-neighbour at each fragment's interpolated UV.
    atlas: ?*const Texture = null,

    /// Begin rendering into `target`, clearing it to `clear` (RGBA, 0..1).
    pub fn beginRendering(self: *CommandList, target: *Texture, clear: [4]f32) void {
        self.target = target;
        const px = [4]u8{ toU8(clear[0]), toU8(clear[1]), toU8(clear[2]), toU8(clear[3]) };
        var i: usize = 0;
        while (i < target.pixels.len) : (i += 4) {
            target.pixels[i + 0] = px[0];
            target.pixels[i + 1] = px[1];
            target.pixels[i + 2] = px[2];
            target.pixels[i + 3] = px[3];
        }
    }

    /// Bind the scene pipeline. Clears the textured flag: the next `draw` rasterizes
    /// flat `port.Vertex` quads. The rasterizer itself is fixed-function.
    pub fn bindPipeline(self: *CommandList, pipeline: *Pipeline) void {
        _ = pipeline;
        self.textured = false;
    }

    /// Bind the textured sprite pipeline (ADR 0031 §4): the next `draw` interprets its
    /// vertices as `port.TexturedVertex` and fills each quad with its tint. `pipeline`
    /// carries no state on the null backend.
    pub fn bindTexturedPipeline(self: *CommandList, pipeline: *TexturedPipeline) void {
        _ = pipeline;
        self.textured = true;
    }

    /// Bind `tex` as the sampled atlas for the textured pipeline: the next textured
    /// `draw` samples its pixels nearest-neighbour at each fragment's interpolated UV
    /// (ADR 0031 §4). `pipeline` carries no state on the null backend. `tex` is borrowed
    /// and must outlive the draw.
    pub fn bindTexture(self: *CommandList, pipeline: *TexturedPipeline, tex: *Texture) void {
        _ = pipeline;
        self.atlas = tex;
    }

    /// Bind the vertex buffer the next `draw` rasterizes.
    pub fn bindVertexBuffer(self: *CommandList, buffer: *Buffer) void {
        self.vertices = buffer.bytes;
    }

    /// Rasterize `vertex_count` vertices (6 per axis-aligned quad) into the bound
    /// target. Each quad's screen rect is filled with its flat colour; NDC maps to
    /// pixels with y increasing downward, matching the Vulkan backend's framebuffer.
    pub fn draw(self: *CommandList, vertex_count: u32) void {
        if (self.textured) return self.drawTextured(vertex_count);
        const target = self.target orelse return;
        const verts = std.mem.bytesAsSlice(port.Vertex, self.vertices);
        const w: f32 = @floatFromInt(target.width);
        const h: f32 = @floatFromInt(target.height);
        var base: usize = 0;
        while (base + 6 <= vertex_count) : (base += 6) {
            var min_x: f32 = verts[base].x;
            var max_x: f32 = verts[base].x;
            var min_y: f32 = verts[base].y;
            var max_y: f32 = verts[base].y;
            for (verts[base .. base + 6]) |v| {
                min_x = @min(min_x, v.x);
                max_x = @max(max_x, v.x);
                min_y = @min(min_y, v.y);
                max_y = @max(max_y, v.y);
            }
            const c = [3]u8{ toU8(verts[base].r), toU8(verts[base].g), toU8(verts[base].b) };
            const x0 = clampPx(ndcToPx(min_x, w), target.width);
            const x1 = clampPx(ndcToPx(max_x, w), target.width);
            const y0 = clampPx(ndcToPx(min_y, h), target.height);
            const y1 = clampPx(ndcToPx(max_y, h), target.height);
            var y = y0;
            while (y < y1) : (y += 1) {
                var x = x0;
                while (x < x1) : (x += 1) {
                    const i = (@as(usize, y) * target.width + x) * 4;
                    target.pixels[i + 0] = c[0];
                    target.pixels[i + 1] = c[1];
                    target.pixels[i + 2] = c[2];
                    target.pixels[i + 3] = 255;
                }
            }
        }
    }

    /// Rasterize `vertex_count` textured vertices (6 per quad → two triangles) into the
    /// bound target, sampling the bound atlas (ADR 0031 §4). This is a REAL textured
    /// rasterizer, not a flat-fill: for each covered fragment it barycentric-interpolates
    /// the UV across the (possibly rotated) triangle, samples the atlas nearest-neighbour,
    /// multiplies RGB by the per-vertex tint, and straight-alpha "over"-blends the result —
    /// exactly what `sprite.wgsl` + the Vulkan pipeline's blend do, so a geometry/UV bug in
    /// `render.projectSprites` reproduces headlessly, pixel-for-pixel modulo the diagonal
    /// seam (both sub-triangles fill their shared edge; a top-left fill rule is unneeded for
    /// a deterministic test double). No atlas bound ⇒ nothing is sampled (no-op). Vertices
    /// are `port.TexturedVertex`.
    fn drawTextured(self: *CommandList, vertex_count: u32) void {
        const target = self.target orelse return;
        const atlas = self.atlas orelse return;
        if (atlas.width == 0 or atlas.height == 0) return;
        const verts = std.mem.bytesAsSlice(port.TexturedVertex, self.vertices);
        var base: usize = 0;
        while (base + 6 <= vertex_count) : (base += 6) {
            rasterTexturedTri(target, atlas, verts[base + 0], verts[base + 1], verts[base + 2]);
            rasterTexturedTri(target, atlas, verts[base + 3], verts[base + 4], verts[base + 5]);
        }
    }

    /// End rendering. No-op: immediate-mode writes already landed.
    pub fn endRendering(self: *CommandList) void {
        _ = self;
    }

    /// Copy `texture`'s pixels into `buffer` (readback). Sizes are set up equal by
    /// `renderScene`; the copy is truncated to the smaller of the two for safety.
    pub fn copyTextureToBuffer(self: *CommandList, texture: *Texture, buffer: *Buffer) void {
        _ = self;
        const n = @min(texture.pixels.len, buffer.bytes.len);
        @memcpy(buffer.bytes[0..n], texture.pixels[0..n]);
    }

    /// Release recording resources. No-op for the null backend.
    pub fn deinit(self: *CommandList, dev: *Device) void {
        _ = self;
        _ = dev;
    }
};

/// A CPU "device". Holds only the allocator that owns every resource it creates.
pub const Device = struct {
    gpa: Allocator,

    /// Acquire the null device. Never fails; `!Device` matches the Vulkan backend's
    /// fallible signature so `renderScene` is backend-agnostic.
    pub fn init(gpa: Allocator) !Device {
        return .{ .gpa = gpa };
    }

    /// Release the device. No-op: resources are freed by their own `deinit`.
    pub fn deinit(self: *Device) void {
        _ = self;
    }

    /// Create a colour target sized by `desc`, zero-initialized. Caller frees via
    /// `Texture.deinit`. Errors: `error.OutOfMemory`.
    pub fn createTexture(self: *Device, desc: port.TextureDesc) !Texture {
        const pixels = try self.gpa.alloc(u8, @as(usize, desc.width) * desc.height * 4);
        @memset(pixels, 0);
        return .{ .width = desc.width, .height = desc.height, .pixels = pixels };
    }

    /// Create a host byte buffer sized by `desc`. Caller frees via `Buffer.deinit`.
    /// Errors: `error.OutOfMemory`.
    pub fn createBuffer(self: *Device, desc: port.BufferDesc) !Buffer {
        return .{ .bytes = try self.gpa.alloc(u8, @intCast(desc.size)) };
    }

    /// Upload tightly-packed RGBA8 `rgba` into `tex` (ADR 0031: a decoded sprite sheet
    /// reaching the GPU). On the null backend this copies the bytes into the texture's
    /// host pixel buffer — a real adapter (the bytes are tracked and readable) — and the
    /// null textured rasterizer samples them nearest-neighbour when `tex` is the bound
    /// atlas (`drawTextured`). `rgba.len` must equal the texture's byte size.
    /// `dev` is unused (host memory) but kept for surface parity with the Vulkan backend,
    /// which needs the device to stage the copy. Never fails on the null backend; `!void`
    /// matches the Vulkan backend's fallible upload.
    pub fn uploadTexture(self: *Device, tex: *Texture, rgba: []const u8) !void {
        _ = self;
        std.debug.assert(rgba.len == tex.pixels.len);
        @memcpy(tex.pixels, rgba);
    }

    /// Create the scene pipeline. Trivial for the null backend. `format` is accepted
    /// for surface parity. Never fails.
    pub fn createScenePipeline(self: *Device, format: port.TextureFormat) !Pipeline {
        _ = self;
        _ = format;
        return .{};
    }

    /// Create the textured sprite pipeline (ADR 0031 §4). Trivial for the null backend
    /// (it fills flat tint rather than sampling); `format` is accepted for surface
    /// parity with the Vulkan backend. Never fails.
    pub fn createTexturedPipeline(self: *Device, format: port.TextureFormat) !TexturedPipeline {
        _ = self;
        _ = format;
        return .{};
    }

    /// Begin recording. Returns an empty immediate-mode command list. Never fails.
    pub fn beginCommands(self: *Device) !CommandList {
        _ = self;
        return .{};
    }

    /// Submit recorded work. No-op: the null command list wrote immediately.
    pub fn submit(self: *Device, cmd: *CommandList) !void {
        _ = self;
        _ = cmd;
    }

    /// Create a headless swapchain: a single CPU colour target sized by `desc`
    /// (ADR 0012). `desc.surface` is ignored — headless has no OS window, so the null
    /// backend accepts a null surface handle. Caller frees via `Swapchain.deinit`.
    /// Errors: `error.OutOfMemory`.
    pub fn createSwapchain(self: *Device, desc: port.SwapchainDesc) !Swapchain {
        const image = try self.createTexture(.{
            .width = desc.width,
            .height = desc.height,
            .format = desc.format,
            .usage = .{ .color_attachment = true, .transfer_src = true },
        });
        return .{
            .image = image,
            .presented = &.{},
            .present_count = 0,
            .format = desc.format,
            .present_mode = desc.present_mode,
        };
    }
};

/// One acquired swapchain image for the frame being rendered. `target` is the null
/// backend's CPU colour target; the caller records a `CommandList` into it, then
/// `present`s this frame. Borrowed — valid until the matching `present`.
pub const Frame = struct {
    /// The image to render into this frame.
    target: *Texture,
    /// Index of the acquired image (always 0: the null chain has one image). Present
    /// for parity with a multi-image Vulkan swapchain.
    index: u32,
    /// Whether the acquired image is optimal for the surface (null: always `.optimal`).
    status: port.AcquireStatus,
};

/// The null presentation swapchain — a real, headless adapter satisfying the same
/// acquire→render→present surface the Vulkan backend will implement (ADR 0012). It
/// owns one CPU colour target; `acquire` hands it out, `present` captures its pixels
/// (so a headless run is observable) and is otherwise a no-op, `resize` reallocates
/// it. It never goes out of date, so every status is `.optimal`.
pub const Swapchain = struct {
    /// The single CPU image the null swapchain presents; the `acquire` target.
    image: Texture,
    /// Copy of the most recently presented pixels (RGBA8), owned by `dev.gpa`, or
    /// empty before the first present. Lets a headless present be inspected in tests.
    presented: []u8,
    /// Count of frames presented; a headless present is a no-op beyond this capture.
    present_count: u64,
    /// Format of the image, reused when `resize` reallocates the target.
    format: port.TextureFormat,
    /// The requested present mode. Retained only for surface parity with the Vulkan
    /// backend (which selects a `VkPresentModeKHR` from it); a headless present has no
    /// display queue, so nothing here reads it — `.optimal` is always reported.
    present_mode: port.PresentMode,

    /// Release the image and the presented-frame capture. `dev` owns the allocator.
    pub fn deinit(self: *Swapchain, dev: *Device) void {
        self.image.deinit(dev);
        dev.gpa.free(self.presented);
    }

    /// Acquire the next image to render into. The null chain has one image and never
    /// goes out of date, so this always returns it, `.optimal`. `dev` is unused (kept
    /// for parity with the Vulkan backend's fallible acquire). Never fails.
    pub fn acquire(self: *Swapchain, dev: *Device) !Frame {
        _ = dev;
        return .{ .target = &self.image, .index = 0, .status = .optimal };
    }

    /// Present `frame`. The null backend captures the image's pixels into `presented`
    /// (so a headless run can be inspected) and reports `.optimal`. `frame.target`
    /// must be this swapchain's image. Errors: `error.OutOfMemory` growing the capture.
    pub fn present(self: *Swapchain, dev: *Device, frame: Frame) !port.AcquireStatus {
        // Proof: the null chain hands out only `&self.image` from `acquire`, so a
        // frame presented to its own swapchain always targets that image.
        std.debug.assert(frame.target == &self.image);
        if (self.presented.len != self.image.pixels.len) {
            self.presented = try dev.gpa.realloc(self.presented, self.image.pixels.len);
        }
        @memcpy(self.presented, self.image.pixels);
        self.present_count += 1;
        return .optimal;
    }

    /// Resize the swapchain's image to `width`×`height` (the surface/window resized;
    /// the Vulkan analogue recreates on `out_of_date`). Reallocates the render target;
    /// the stale one is freed. Errors: `error.OutOfMemory`.
    pub fn resize(self: *Swapchain, dev: *Device, width: u32, height: u32) !void {
        const image = try dev.createTexture(.{
            .width = width,
            .height = height,
            .format = self.format,
            .usage = .{ .color_attachment = true, .transfer_src = true },
        });
        self.image.deinit(dev);
        self.image = image;
    }
};

fn toU8(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

fn ndcToPx(ndc: f32, dim: f32) i64 {
    return @intFromFloat(@floor((ndc + 1) * 0.5 * dim));
}

fn clampPx(px: i64, dim: u32) u32 {
    return @intCast(std.math.clamp(px, 0, @as(i64, dim)));
}

/// NDC coordinate `ndc` (−1..1) to a continuous pixel coordinate on a `dim`-wide axis; y
/// increases downward, matching the framebuffer and the flat rasterizer's `ndcToPx`.
fn ndcToPxF(ndc: f32, dim: u32) f32 {
    return (ndc + 1) * 0.5 * @as(f32, @floatFromInt(dim));
}

/// Nearest-neighbour texel index for atlas UV `coord` on a `dim`-texel axis: `floor(coord *
/// dim)` clamped to `[0, dim)` — the clamp-to-edge nearest filter the Vulkan sampler uses.
fn sampleAxis(coord: f32, dim: u32) u32 {
    const t: i64 = @intFromFloat(@floor(coord * @as(f32, @floatFromInt(dim))));
    return @intCast(std.math.clamp(t, 0, @as(i64, dim) - 1));
}

/// Rasterize one textured triangle (`a`,`b`,`c` in `port.TexturedVertex`) into `target`,
/// sampling `atlas`. Walks the triangle's pixel bounding box, keeps fragments whose centre
/// is inside (barycentric coords all ≥ 0, winding-agnostic), interpolates UV there, samples
/// the atlas nearest-neighbour, tints RGB and straight-alpha "over"-blends onto `target`.
/// Tint is taken from `a` (the vertex builder gives all three corners the same tint).
fn rasterTexturedTri(target: *Texture, atlas: *const Texture, a: port.TexturedVertex, b: port.TexturedVertex, c: port.TexturedVertex) void {
    const ax = ndcToPxF(a.x, target.width);
    const ay = ndcToPxF(a.y, target.height);
    const bx = ndcToPxF(b.x, target.width);
    const by = ndcToPxF(b.y, target.height);
    const cx = ndcToPxF(c.x, target.width);
    const cy = ndcToPxF(c.y, target.height);

    const denom = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy);
    if (denom == 0) return; // degenerate (zero-area) triangle
    const inv = 1.0 / denom;

    const x0 = clampPx(@intFromFloat(@floor(@min(ax, @min(bx, cx)))), target.width);
    const x1 = clampPx(@intFromFloat(@ceil(@max(ax, @max(bx, cx)))), target.width);
    const y0 = clampPx(@intFromFloat(@floor(@min(ay, @min(by, cy)))), target.height);
    const y1 = clampPx(@intFromFloat(@ceil(@max(ay, @max(by, cy)))), target.height);
    const tint = [3]f32{ a.r, a.g, a.b };

    var py = y0;
    while (py < y1) : (py += 1) {
        const sy = @as(f32, @floatFromInt(py)) + 0.5;
        var px = x0;
        while (px < x1) : (px += 1) {
            const sx = @as(f32, @floatFromInt(px)) + 0.5;
            const l0 = ((by - cy) * (sx - cx) + (cx - bx) * (sy - cy)) * inv;
            const l1 = ((cy - ay) * (sx - cx) + (ax - cx) * (sy - cy)) * inv;
            const l2 = 1.0 - l0 - l1;
            if (l0 < 0 or l1 < 0 or l2 < 0) continue;
            const u = l0 * a.u + l1 * b.u + l2 * c.u;
            const v = l0 * a.v + l1 * b.v + l2 * c.v;
            blendTexel(target, atlas, px, py, u, v, tint);
        }
    }
}

/// Sample `atlas` at UV (`u`,`v`) nearest-neighbour, tint its RGB, and straight-alpha
/// "over"-blend it onto `target` pixel (`px`,`py`): `out = src·a + dst·(1−a)` for colour
/// and `a + dst_a·(1−a)` for alpha — matching `sprite.wgsl` (`rgb·tint`, alpha passthrough)
/// and the Vulkan src-alpha-over blend. `px`/`py` are in bounds (the caller clamps).
fn blendTexel(target: *Texture, atlas: *const Texture, px: u32, py: u32, u: f32, v: f32, tint: [3]f32) void {
    const s = (@as(usize, sampleAxis(v, atlas.height)) * atlas.width + sampleAxis(u, atlas.width)) * 4;
    const sa = @as(f32, @floatFromInt(atlas.pixels[s + 3])) / 255.0;
    const sr = @as(f32, @floatFromInt(atlas.pixels[s + 0])) / 255.0 * tint[0];
    const sg = @as(f32, @floatFromInt(atlas.pixels[s + 1])) / 255.0 * tint[1];
    const sb = @as(f32, @floatFromInt(atlas.pixels[s + 2])) / 255.0 * tint[2];

    const d = (@as(usize, py) * target.width + px) * 4;
    const dr = @as(f32, @floatFromInt(target.pixels[d + 0])) / 255.0;
    const dg = @as(f32, @floatFromInt(target.pixels[d + 1])) / 255.0;
    const db = @as(f32, @floatFromInt(target.pixels[d + 2])) / 255.0;
    const da = @as(f32, @floatFromInt(target.pixels[d + 3])) / 255.0;

    target.pixels[d + 0] = toU8(sr * sa + dr * (1 - sa));
    target.pixels[d + 1] = toU8(sg * sa + dg * (1 - sa));
    target.pixels[d + 2] = toU8(sb * sa + db * (1 - sa));
    target.pixels[d + 3] = toU8(sa + da * (1 - sa));
}

const testing = std.testing;

test "null backend: renderScene surface clears then rasterizes a quad" {
    var dev = try Device.init(testing.allocator);
    defer dev.deinit();

    var target = try dev.createTexture(.{ .width = 8, .height = 8, .format = .rgba8_unorm, .usage = .{ .color_attachment = true, .transfer_src = true } });
    defer target.deinit(&dev);

    // One red quad covering the top-left NDC quadrant: x,y in [-1, 0].
    const red = [3]f32{ 1, 0, 0 };
    const q = [_]port.Vertex{
        .{ .x = -1, .y = -1, .r = red[0], .g = red[1], .b = red[2] },
        .{ .x = 0, .y = -1, .r = red[0], .g = red[1], .b = red[2] },
        .{ .x = -1, .y = 0, .r = red[0], .g = red[1], .b = red[2] },
        .{ .x = -1, .y = 0, .r = red[0], .g = red[1], .b = red[2] },
        .{ .x = 0, .y = -1, .r = red[0], .g = red[1], .b = red[2] },
        .{ .x = 0, .y = 0, .r = red[0], .g = red[1], .b = red[2] },
    };
    var vbuf = try dev.createBuffer(.{ .size = @sizeOf(@TypeOf(q)), .usage = .{ .vertex = true } });
    defer vbuf.deinit(&dev);
    try vbuf.write(&dev, std.mem.asBytes(&q));

    var readback = try dev.createBuffer(.{ .size = target.pixels.len, .usage = .{ .transfer_dst = true } });
    defer readback.deinit(&dev);

    var pipe = try dev.createScenePipeline(.rgba8_unorm);
    defer pipe.deinit(&dev);

    var cmd = try dev.beginCommands();
    defer cmd.deinit(&dev);
    cmd.beginRendering(&target, .{ 0, 0, 0, 1 });
    cmd.bindPipeline(&pipe);
    cmd.bindVertexBuffer(&vbuf);
    cmd.draw(6);
    cmd.endRendering();
    cmd.copyTextureToBuffer(&target, &readback);
    try dev.submit(&cmd);

    const out = try readback.read(&dev, testing.allocator);
    defer testing.allocator.free(out);

    // Top-left pixel is inside the quad → red; bottom-right is outside → clear black.
    try testing.expectEqual(@as(u8, 255), out[0]); // (0,0) R
    try testing.expectEqual(@as(u8, 0), out[1]); // (0,0) G
    const last = (7 * 8 + 7) * 4;
    try testing.expectEqual(@as(u8, 0), out[last + 0]); // (7,7) R stayed clear
    try testing.expectEqual(@as(u8, 255), out[last + 3]); // (7,7) A from clear
}

test "null backend: uploadTexture copies RGBA bytes into a sampled texture" {
    var dev = try Device.init(testing.allocator);
    defer dev.deinit();

    // A 2x2 sprite-sheet-style texture: transfer_dst (upload) + sampled (shader read).
    var tex = try dev.createTexture(.{ .width = 2, .height = 2, .format = .rgba8_unorm, .usage = .{ .transfer_dst = true, .sampled = true } });
    defer tex.deinit(&dev);

    var rgba: [2 * 2 * 4]u8 = undefined;
    for (&rgba, 0..) |*b, i| b.* = @intCast(i * 5 & 0xff);
    try dev.uploadTexture(&tex, &rgba);

    // The null adapter really holds the uploaded bytes (a readable test double), even
    // though its rasterizer draws flat colour rather than sampling them.
    try testing.expectEqualSlices(u8, &rgba, tex.pixels);
}

test "null backend: textured draw samples the atlas nearest-neighbour and alpha-blends" {
    var dev = try Device.init(testing.allocator);
    defer dev.deinit();

    // A 2x1 atlas: left texel opaque red, right texel 50%-alpha green.
    var atlas = try dev.createTexture(.{ .width = 2, .height = 1, .format = .rgba8_unorm, .usage = .{ .transfer_dst = true, .sampled = true } });
    defer atlas.deinit(&dev);
    try dev.uploadTexture(&atlas, &.{ 255, 0, 0, 255, 0, 255, 0, 128 });

    var target = try dev.createTexture(.{ .width = 8, .height = 8, .format = .rgba8_unorm, .usage = .{ .color_attachment = true, .transfer_src = true } });
    defer target.deinit(&dev);

    // A full-frame textured quad (TL,TR,BL, BL,TR,BR), UVs spanning the whole atlas, no
    // rotation, white tint — the exact 6-vertex layout `buildTexturedVertices` emits.
    const white = [3]f32{ 1, 1, 1 };
    const q = [_]port.TexturedVertex{
        .{ .x = -1, .y = -1, .u = 0, .v = 0, .r = white[0], .g = white[1], .b = white[2] }, // TL
        .{ .x = 1, .y = -1, .u = 1, .v = 0, .r = white[0], .g = white[1], .b = white[2] }, // TR
        .{ .x = -1, .y = 1, .u = 0, .v = 1, .r = white[0], .g = white[1], .b = white[2] }, // BL
        .{ .x = -1, .y = 1, .u = 0, .v = 1, .r = white[0], .g = white[1], .b = white[2] }, // BL
        .{ .x = 1, .y = -1, .u = 1, .v = 0, .r = white[0], .g = white[1], .b = white[2] }, // TR
        .{ .x = 1, .y = 1, .u = 1, .v = 1, .r = white[0], .g = white[1], .b = white[2] }, // BR
    };
    var vbuf = try dev.createBuffer(.{ .size = @sizeOf(@TypeOf(q)), .usage = .{ .vertex = true } });
    defer vbuf.deinit(&dev);
    try vbuf.write(&dev, std.mem.asBytes(&q));

    var pipe = try dev.createTexturedPipeline(.rgba8_unorm);
    defer pipe.deinit(&dev);

    var cmd = try dev.beginCommands();
    defer cmd.deinit(&dev);
    cmd.beginRendering(&target, .{ 0, 0, 1, 1 }); // opaque blue clear
    cmd.bindTexturedPipeline(&pipe);
    cmd.bindTexture(&pipe, &atlas);
    cmd.bindVertexBuffer(&vbuf);
    cmd.draw(6);
    cmd.endRendering();
    try dev.submit(&cmd);

    // Left half (u<0.5) samples the opaque red texel → red, blue clear fully covered.
    const left = (4 * 8 + 1) * 4;
    try testing.expectEqual(@as(u8, 255), target.pixels[left + 0]);
    try testing.expectEqual(@as(u8, 0), target.pixels[left + 1]);
    try testing.expectEqual(@as(u8, 0), target.pixels[left + 2]);
    // Right half (u≥0.5) samples the 50%-alpha green texel: it blends over the blue clear —
    // proof the null backend really samples texels AND alpha-composites (not a flat fill).
    const right = (4 * 8 + 6) * 4;
    try testing.expectEqual(@as(u8, 0), target.pixels[right + 0]); // no red
    try testing.expectEqual(@as(u8, 128), target.pixels[right + 1]); // 0.502·green
    try testing.expectEqual(@as(u8, 127), target.pixels[right + 2]); // 0.498·blue shows through
}

test "null backend: a textured draw with no atlas bound samples nothing" {
    var dev = try Device.init(testing.allocator);
    defer dev.deinit();
    var target = try dev.createTexture(.{ .width = 4, .height = 4, .format = .rgba8_unorm, .usage = .{ .color_attachment = true, .transfer_src = true } });
    defer target.deinit(&dev);

    const q = [_]port.TexturedVertex{
        .{ .x = -1, .y = -1, .u = 0, .v = 0, .r = 1, .g = 1, .b = 1 },
        .{ .x = 1, .y = -1, .u = 1, .v = 0, .r = 1, .g = 1, .b = 1 },
        .{ .x = -1, .y = 1, .u = 0, .v = 1, .r = 1, .g = 1, .b = 1 },
        .{ .x = -1, .y = 1, .u = 0, .v = 1, .r = 1, .g = 1, .b = 1 },
        .{ .x = 1, .y = -1, .u = 1, .v = 0, .r = 1, .g = 1, .b = 1 },
        .{ .x = 1, .y = 1, .u = 1, .v = 1, .r = 1, .g = 1, .b = 1 },
    };
    var vbuf = try dev.createBuffer(.{ .size = @sizeOf(@TypeOf(q)), .usage = .{ .vertex = true } });
    defer vbuf.deinit(&dev);
    try vbuf.write(&dev, std.mem.asBytes(&q));
    var pipe = try dev.createTexturedPipeline(.rgba8_unorm);
    defer pipe.deinit(&dev);

    var cmd = try dev.beginCommands();
    defer cmd.deinit(&dev);
    cmd.beginRendering(&target, .{ 0, 0, 0, 1 });
    cmd.bindTexturedPipeline(&pipe);
    // No bindTexture → the textured draw must be a no-op, leaving the clear intact.
    cmd.bindVertexBuffer(&vbuf);
    cmd.draw(6);
    cmd.endRendering();
    try dev.submit(&cmd);

    for (0..4 * 4) |p| try testing.expectEqual(@as(u8, 0), target.pixels[p * 4 + 0]);
}

test "null backend: swapchain acquire -> render -> present captures the frame" {
    var dev = try Device.init(testing.allocator);
    defer dev.deinit();

    // Headless swapchain: a null surface handle, 4x4 target.
    var sc = try dev.createSwapchain(.{
        .surface = .{},
        .width = 4,
        .height = 4,
        .format = .rgba8_unorm,
        .present_mode = .fifo,
    });
    defer sc.deinit(&dev);

    const frame = try sc.acquire(&dev);
    try testing.expectEqual(port.AcquireStatus.optimal, frame.status);
    try testing.expectEqual(@as(u32, 0), frame.index);

    // Render into the acquired image: clear it opaque green.
    var cmd = try dev.beginCommands();
    defer cmd.deinit(&dev);
    cmd.beginRendering(frame.target, .{ 0, 1, 0, 1 });
    cmd.endRendering();
    try dev.submit(&cmd);

    const status = try sc.present(&dev, frame);
    try testing.expectEqual(port.AcquireStatus.optimal, status);
    try testing.expectEqual(@as(u64, 1), sc.present_count);

    // The presented capture holds the green clear (R=0, G=255, A=255).
    try testing.expectEqual(@as(u8, 0), sc.presented[0]);
    try testing.expectEqual(@as(u8, 255), sc.presented[1]);
    try testing.expectEqual(@as(u8, 255), sc.presented[3]);

    // Resize recreates the target; a fresh acquire yields the new drawable size.
    try sc.resize(&dev, 8, 8);
    const bigger = try sc.acquire(&dev);
    try testing.expectEqual(@as(u32, 8), bigger.target.width);
    try testing.expectEqual(@as(u32, 8), bigger.target.height);
}
