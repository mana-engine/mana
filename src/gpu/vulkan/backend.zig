//! Vulkan gpu backend (ADR 0006 offscreen; ADR 0012 present), compiled only under
//! `-Denable-vulkan`. It implements the engine-owned port surface (ADR 0010): a
//! `Device` creates `Texture`/`Buffer`/`Pipeline` resources and a `CommandList`, and
//! the shared `gpu.renderScene` driver records draws + a readback through them. Here
//! those types are Vulkan handles (image/view/memory, buffer, graphics pipeline,
//! command buffer) driven via dynamic rendering; Vulkan types stay inside this subtree
//! — the port surface above is plain data. The loader (`vulkan-1`) is loaded
//! dynamically at runtime, so no import library / Vulkan SDK is needed.
//!
//! It also implements the ADR 0012 presentation surface — `Device.createSwapchain` and
//! the `Swapchain`/`Frame` acquire → render → present → resize path over a real
//! `VkSurfaceKHR`/`VkSwapchainKHR`. The surface is built from the platform's opaque
//! `SDL_Window*` via `SDL_Vulkan_CreateSurface`, declared as C externs so this backend
//! never imports `platform` (ADR 0012 §8); the SDL3 artifact is linked into `gpu` only
//! under `-Denable-sdl3 -Denable-vulkan`. A vulkan-only build has no window system, so
//! `createSwapchain` returns `error.NotImplemented`. Present cannot be exercised on
//! headless CI (no display/GPU); it is a manual acceptance step.
//!
//! Over the ~500-line soft limit by design: this is one irreducibly verbose Vulkan
//! backend — device/pipeline/command/barrier + swapchain boilerplate — kept as a single
//! unit behind the `gpu` port. Splitting the handles across files would scatter tightly
//! coupled boilerplate without reducing it.

const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const build_options = @import("build_options");
const windows = std.os.windows;
const port = @import("../port.zig");
const Allocator = std.mem.Allocator;

// SDL3 Vulkan interop, declared as C externs so this backend can build a
// `VkSurfaceKHR` from the platform's opaque `SDL_Window*` WITHOUT importing the
// `platform` module — the module DAG (`gpu → core`, never `gpu → platform`) stays
// intact (ADR 0012, "Vulkan surface creation"). These symbols are *referenced* only
// under `build_options.enable_sdl3`; `build.zig` links the SDL3 artifact into the
// `gpu` module exactly when both `-Denable-sdl3` and `-Denable-vulkan` are set, so a
// vulkan-only or default build never needs (or links) them. Signatures mirror
// `<SDL3/SDL_vulkan.h>`: `bool` is C `_Bool`, `?*anyopaque` the `SDL_Window*`.
extern fn SDL_WasInit(flags: u32) callconv(.c) u32;
extern fn SDL_Vulkan_GetInstanceExtensions(count: *u32) callconv(.c) ?[*]const [*:0]const u8;
extern fn SDL_Vulkan_CreateSurface(
    window: ?*anyopaque,
    instance: vk.Instance,
    allocator: ?*const vk.AllocationCallbacks,
    surface: *vk.SurfaceKHR,
) callconv(.c) bool;

/// `SDL_INIT_VIDEO` (from `<SDL3/SDL_init.h>`): the subsystem whose presence means a
/// window can exist, hence a surface can be built. `SDL_Vulkan_GetInstanceExtensions`
/// dereferences the video device, so it must not be called before video is initialised.
const SDL_INIT_VIDEO: u32 = 0x0000_0020;

/// Vulkan API version this backend targets (1.3 for core dynamic rendering).
pub const target_api_version: u32 = @bitCast(vk.API_VERSION_1_3);

/// Scene shaders, compiled from WGSL by naga (`mise run shaders`). Aligned to u32
/// so it can be handed to Vulkan directly.
const scene_spv align(@alignOf(u32)) = @embedFile("shaders/scene.spv").*;

/// Sprite (textured-quad) shaders, compiled from `shaders/sprite.wgsl` by naga
/// (`mise run shaders`; ADR 0031 §4). Aligned to u32 so it can be handed to Vulkan
/// directly. This file is a DERIVED artifact committed alongside the WGSL source, like
/// `scene.spv`; a build under `-Denable-vulkan` fails until it is generated.
const sprite_spv align(@alignOf(u32)) = @embedFile("shaders/sprite.spv").*;

/// Full colour subresource range (single mip, single layer) used by every image op.
const full_range: vk.ImageSubresourceRange = .{
    .aspect_mask = .{ .color_bit = true },
    .base_mip_level = 0,
    .level_count = 1,
    .base_array_layer = 0,
    .layer_count = 1,
};

// std.DynLib has no Windows implementation in Zig 0.16, so Windows loads the
// loader through kernel32; posix uses DynLib.
extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?windows.HMODULE;
extern "kernel32" fn GetProcAddress(module: windows.HMODULE, name: [*:0]const u8) callconv(.winapi) ?windows.FARPROC;
extern "kernel32" fn FreeLibrary(module: windows.HMODULE) callconv(.winapi) windows.BOOL;

const posix_loader_names = [_][]const u8{ "libvulkan.so.1", "libvulkan.so", "libvulkan.dylib", "libvulkan.1.dylib" };

const Loader = struct {
    handle: if (builtin.os.tag == .windows) windows.HMODULE else std.DynLib,
    get_proc: vk.PfnGetInstanceProcAddr,

    fn open() ?Loader {
        if (builtin.os.tag == .windows) {
            const module = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("vulkan-1.dll")) orelse return null;
            const proc = GetProcAddress(module, "vkGetInstanceProcAddr") orelse {
                _ = FreeLibrary(module);
                return null;
            };
            return .{ .handle = module, .get_proc = @ptrCast(proc) };
        } else {
            for (posix_loader_names) |name| {
                var lib = std.DynLib.open(name) catch continue;
                if (lib.lookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr")) |p| {
                    return .{ .handle = lib, .get_proc = p };
                }
                lib.close();
            }
            return null;
        }
    }

    fn close(self: *Loader) void {
        if (builtin.os.tag == .windows) {
            _ = FreeLibrary(self.handle);
        } else {
            self.handle.close();
        }
    }
};

/// Map the port's pixel format to a Vulkan format. Only the one format the renderer
/// uses is defined (ADR 0010: no speculative widening).
fn formatToVk(f: port.TextureFormat) vk.Format {
    return switch (f) {
        .rgba8_unorm => .r8g8b8a8_unorm,
    };
}

/// An offscreen colour target: a device-local image, its view, and backing memory.
pub const Texture = struct {
    image: vk.Image,
    view: vk.ImageView,
    memory: vk.DeviceMemory,
    width: u32,
    height: u32,
    format: vk.Format,

    /// Destroy the view, image, and free its memory. `dev` owns the GPU objects.
    pub fn deinit(self: *Texture, dev: *Device) void {
        const d = dev.device();
        d.destroyImageView(self.view, null);
        d.destroyImage(self.image, null);
        d.freeMemory(self.memory, null);
    }
};

/// A host-visible, host-coherent Vulkan buffer (vertex upload or image readback).
pub const Buffer = struct {
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    size: u64,

    /// Destroy the buffer and free its memory. `dev` owns the GPU objects.
    pub fn deinit(self: *Buffer, dev: *Device) void {
        const d = dev.device();
        d.destroyBuffer(self.buffer, null);
        d.freeMemory(self.memory, null);
    }

    /// Map the buffer, copy `data` in from offset 0, and unmap. `data.len` must not
    /// exceed the buffer's size; caller owns `data`. Errors: Vulkan map failure.
    pub fn write(self: *Buffer, dev: *Device, data: []const u8) !void {
        const d = dev.device();
        const mapped = try d.mapMemory(self.memory, 0, self.size, .{});
        const dst: [*]u8 = @ptrCast(mapped.?);
        @memcpy(dst[0..data.len], data);
        d.unmapMemory(self.memory);
    }

    /// Map the buffer and return a `gpa`-owned copy of its bytes (the read-back
    /// image). Errors: Vulkan map failure or `error.OutOfMemory`.
    pub fn read(self: *Buffer, dev: *Device, gpa: Allocator) ![]u8 {
        const d = dev.device();
        const mapped = try d.mapMemory(self.memory, 0, self.size, .{});
        defer d.unmapMemory(self.memory);
        const src: [*]const u8 = @ptrCast(mapped.?);
        return gpa.dupe(u8, src[0..@intCast(self.size)]);
    }
};

/// The scene graphics pipeline and its (empty) layout.
pub const Pipeline = struct {
    pipeline: vk.Pipeline,
    layout: vk.PipelineLayout,

    /// Destroy the pipeline and layout. `dev` owns the GPU objects.
    pub fn deinit(self: *Pipeline, dev: *Device) void {
        const d = dev.device();
        d.destroyPipeline(self.pipeline, null);
        d.destroyPipelineLayout(self.layout, null);
    }
};

/// The textured sprite pipeline (ADR 0031 §4): a blend-enabled graphics pipeline whose
/// fragment stage samples a bound atlas via a combined `texture_2d` + `sampler`, plus
/// the descriptor machinery that binds that atlas. naga emits the WGSL `texture_2d` and
/// `sampler` as **two** distinct descriptors, so the set layout has binding 0 =
/// sampled image and binding 1 = sampler. One descriptor set is allocated up front and
/// re-pointed at the current atlas by `CommandList.bindTexture` — safe because the
/// backend renders synchronously (`submit` waits idle), so the set is never updated
/// while a submission using it is in flight.
pub const TexturedPipeline = struct {
    pipeline: vk.Pipeline,
    layout: vk.PipelineLayout,
    set_layout: vk.DescriptorSetLayout,
    sampler: vk.Sampler,
    pool: vk.DescriptorPool,
    set: vk.DescriptorSet,

    /// Destroy the pipeline, layout, descriptor pool (freeing its set), set layout, and
    /// sampler. `dev` owns the GPU objects.
    pub fn deinit(self: *TexturedPipeline, dev: *Device) void {
        const d = dev.device();
        d.destroyPipeline(self.pipeline, null);
        d.destroyPipelineLayout(self.layout, null);
        d.destroyDescriptorPool(self.pool, null);
        d.destroyDescriptorSetLayout(self.set_layout, null);
        d.destroySampler(self.sampler, null);
    }
};

/// Records one submission's worth of commands into a primary command buffer, owning
/// the pool it was allocated from. Method shapes mirror the null backend so
/// `gpu.renderScene` is backend-agnostic.
pub const CommandList = struct {
    dev: *Device,
    pool: vk.CommandPool,
    cmd: vk.CommandBuffer,

    /// Transition `target` to colour-attachment layout and begin dynamic rendering,
    /// clearing to `clear` (RGBA, 0..1); also sets a full-image viewport and scissor.
    ///
    /// The viewport is **Y-flipped** (origin at `y = height`, negative `height`) on
    /// purpose (issue #148). The engine emits NDC with **Y pointing down**: `screen.y = 0`
    /// maps to `ndc.y = -1` (`render.projectPoint`/`projectSprites`), which the null CPU
    /// rasterizer honours directly (`ndcToPxF`: `ndc.y = -1` → pixel row 0 = top). naga,
    /// however, compiles our WGSL under the WebGPU clip-space convention (Y up) and injects
    /// `position.y = -position.y` into every vertex shader (present in both `scene.spv` and
    /// `sprite.spv`) to retarget it to Vulkan's Y-down clip space. Applied to our
    /// already-Y-down NDC that is a *second* flip, so a positive-height viewport rendered
    /// the whole frame vertically inverted vs. the null/headless capture — invisible on the
    /// near-symmetric maze and on pac, obvious on the V-asymmetric ghost (dome at the
    /// bottom). A negative-height viewport (core since Vulkan 1.1; we target 1.3) cancels
    /// naga's flip, so the live Vulkan image matches the authored, null-rasterized
    /// orientation. Culling is disabled on both pipelines, so the winding change a Y-flip
    /// implies is a no-op.
    pub fn beginRendering(self: *CommandList, target: *Texture, clear: [4]f32) void {
        const d = self.dev.device();
        transition(d, self.cmd, target.image, .undefined, .color_attachment_optimal, .{}, .{ .color_attachment_write_bit = true }, .{ .top_of_pipe_bit = true }, .{ .color_attachment_output_bit = true });
        const attachment: vk.RenderingAttachmentInfo = .{
            .image_view = target.view,
            .image_layout = .color_attachment_optimal,
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .color = .{ .float_32 = clear } },
        };
        d.cmdBeginRendering(self.cmd, &.{
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = target.width, .height = target.height } },
            .layer_count = 1,
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&attachment),
        });
        const h: f32 = @floatFromInt(target.height);
        d.cmdSetViewport(self.cmd, 0, &.{.{ .x = 0, .y = h, .width = @floatFromInt(target.width), .height = -h, .min_depth = 0, .max_depth = 1 }});
        d.cmdSetScissor(self.cmd, 0, &.{.{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = target.width, .height = target.height } }});
    }

    /// Bind the scene pipeline for subsequent draws.
    pub fn bindPipeline(self: *CommandList, pipeline: *Pipeline) void {
        self.dev.device().cmdBindPipeline(self.cmd, .graphics, pipeline.pipeline);
    }

    /// Bind `buffer` as vertex input at binding 0.
    pub fn bindVertexBuffer(self: *CommandList, buffer: *Buffer) void {
        self.dev.device().cmdBindVertexBuffers(self.cmd, 0, &.{buffer.buffer}, &.{0});
    }

    /// Bind the textured sprite pipeline for subsequent draws (ADR 0031 §4).
    pub fn bindTexturedPipeline(self: *CommandList, pipeline: *TexturedPipeline) void {
        self.dev.device().cmdBindPipeline(self.cmd, .graphics, pipeline.pipeline);
    }

    /// Point `pipeline`'s descriptor set at `tex` (the sprite atlas, in
    /// shader-read-only layout after `uploadTexture`) and bind it for subsequent draws.
    /// Updates binding 0 (sampled image = `tex.view`) and binding 1 (`pipeline.sampler`).
    /// Safe to update in-place here: the backend submits synchronously (`submit` waits
    /// idle), so no prior submission still references the set.
    pub fn bindTexture(self: *CommandList, pipeline: *TexturedPipeline, tex: *Texture) void {
        const d = self.dev.device();
        const image_info: vk.DescriptorImageInfo = .{
            .sampler = .null_handle,
            .image_view = tex.view,
            .image_layout = .shader_read_only_optimal,
        };
        const sampler_info: vk.DescriptorImageInfo = .{
            .sampler = pipeline.sampler,
            .image_view = .null_handle,
            .image_layout = .undefined,
        };
        const writes = [_]vk.WriteDescriptorSet{
            .{
                .dst_set = pipeline.set,
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .sampled_image,
                .p_image_info = @ptrCast(&image_info),
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            },
            .{
                .dst_set = pipeline.set,
                .dst_binding = 1,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .sampler,
                .p_image_info = @ptrCast(&sampler_info),
                .p_buffer_info = undefined,
                .p_texel_buffer_view = undefined,
            },
        };
        d.updateDescriptorSets(&writes, &.{});
        d.cmdBindDescriptorSets(self.cmd, .graphics, pipeline.layout, 0, &.{pipeline.set}, &.{});
    }

    /// Draw `vertex_count` vertices (one instance) from the bound vertex buffer.
    pub fn draw(self: *CommandList, vertex_count: u32) void {
        self.dev.device().cmdDraw(self.cmd, vertex_count, 1, 0, 0);
    }

    /// End dynamic rendering.
    pub fn endRendering(self: *CommandList) void {
        self.dev.device().cmdEndRendering(self.cmd);
    }

    /// Transition `texture` to transfer-source layout and copy it into `buffer`
    /// (tightly packed, whole image). Sizes are arranged equal by `renderScene`.
    pub fn copyTextureToBuffer(self: *CommandList, texture: *Texture, buffer: *Buffer) void {
        const d = self.dev.device();
        transition(d, self.cmd, texture.image, .color_attachment_optimal, .transfer_src_optimal, .{ .color_attachment_write_bit = true }, .{ .transfer_read_bit = true }, .{ .color_attachment_output_bit = true }, .{ .transfer_bit = true });
        d.cmdCopyImageToBuffer(self.cmd, texture.image, .transfer_src_optimal, buffer.buffer, &.{.{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = texture.width, .height = texture.height, .depth = 1 },
        }});
    }

    /// Destroy the command pool (freeing its command buffer). `dev` owns it.
    pub fn deinit(self: *CommandList, dev: *Device) void {
        dev.device().destroyCommandPool(self.pool, null);
    }
};

/// A headless Vulkan device: instance, physical device, logical device + graphics
/// queue, with dynamic rendering enabled. Dispatch wrappers are stored by value; the
/// device lives at a stable address (`renderScene`'s local) so proxies rebuilt from
/// `&self.vk*` never dangle.
pub const Device = struct {
    gpa: Allocator,
    loader: Loader,
    vki: vk.InstanceWrapper,
    vkd: vk.DeviceWrapper,
    instance_handle: vk.Instance,
    device_handle: vk.Device,
    pdev: vk.PhysicalDevice,
    mem_props: vk.PhysicalDeviceMemoryProperties,
    family: u32,
    queue: vk.Queue,

    /// Bring up a headless Vulkan device. Errors: loader/instance/device creation
    /// failures, `error.NoVulkanDevice`, `error.NoGraphicsQueue`, `error.OutOfMemory`.
    pub fn init(gpa: Allocator) !Device {
        var loader = Loader.open() orelse return error.VulkanLoaderNotFound;
        errdefer loader.close();
        const vkb = vk.BaseWrapper.load(loader.get_proc);

        const app_info: vk.ApplicationInfo = .{
            .p_application_name = "mana",
            .application_version = @bitCast(vk.makeApiVersion(0, 0, 1, 0)),
            .p_engine_name = "mana",
            .engine_version = @bitCast(vk.makeApiVersion(0, 0, 1, 0)),
            .api_version = target_api_version,
        };
        // A Device created *after* a window exists (SDL video initialised) is
        // present-capable; one created headless (offscreen `renderScene`) is not. Gate
        // the surface/swapchain extensions on that so the offscreen path never touches
        // SDL's Vulkan surface machinery (which crashes if video is uninitialised). The
        // outer `enable_sdl3` guard is comptime, so a vulkan-only/default build never
        // references an SDL symbol and `window_present` folds to a comptime `false` —
        // making the headless vulkan-only device byte-for-byte its prior self.
        const window_present = if (build_options.enable_sdl3) (SDL_WasInit(SDL_INIT_VIDEO) != 0) else false;

        // Windowed present (ADR 0012) needs the platform surface instance extensions;
        // SDL reports exactly which. Only queried when a window exists.
        var surface_ext_count: u32 = 0;
        const surface_exts: ?[*]const [*:0]const u8 = if (window_present)
            (SDL_Vulkan_GetInstanceExtensions(&surface_ext_count) orelse return error.SdlVulkanExtensions)
        else
            null;
        const instance_handle = try vkb.createInstance(&.{
            .p_application_info = &app_info,
            .enabled_extension_count = surface_ext_count,
            .pp_enabled_extension_names = surface_exts,
        }, null);
        var vki = vk.InstanceWrapper.load(instance_handle, vkb.dispatch.vkGetInstanceProcAddr.?);
        const instance = vk.InstanceProxy.init(instance_handle, &vki);
        errdefer instance.destroyInstance(null);

        const pdevs = try instance.enumeratePhysicalDevicesAlloc(gpa);
        defer gpa.free(pdevs);
        if (pdevs.len == 0) return error.NoVulkanDevice;
        const pdev = pdevs[0];
        const family = try graphicsFamily(instance, pdev, gpa);
        const mem_props = instance.getPhysicalDeviceMemoryProperties(pdev);

        const priority = [_]f32{1.0};
        const queue_ci: vk.DeviceQueueCreateInfo = .{ .queue_family_index = family, .queue_count = 1, .p_queue_priorities = &priority };
        var features13: vk.PhysicalDeviceVulkan13Features = .{ .s_type = .physical_device_vulkan_1_3_features, .dynamic_rendering = .true };
        // The swapchain device extension is enabled only for a present-capable device
        // (a window exists); a headless device keeps its exact prior form (no extensions).
        const swapchain_ext: [*:0]const u8 = "VK_KHR_swapchain";
        const device_ext_count: u32 = if (window_present) 1 else 0;
        const device_exts: ?[*]const [*:0]const u8 = if (window_present) @ptrCast(&swapchain_ext) else null;
        const device_handle = try instance.createDevice(pdev, &.{
            .p_next = &features13,
            .queue_create_info_count = 1,
            .p_queue_create_infos = @ptrCast(&queue_ci),
            .enabled_extension_count = device_ext_count,
            .pp_enabled_extension_names = device_exts,
        }, null);
        var vkd = vk.DeviceWrapper.load(device_handle, vki.dispatch.vkGetDeviceProcAddr.?);
        const dev = vk.DeviceProxy.init(device_handle, &vkd);
        errdefer dev.destroyDevice(null);
        const queue = dev.getDeviceQueue(family, 0);

        return .{
            .gpa = gpa,
            .loader = loader,
            .vki = vki,
            .vkd = vkd,
            .instance_handle = instance_handle,
            .device_handle = device_handle,
            .pdev = pdev,
            .mem_props = mem_props,
            .family = family,
            .queue = queue,
        };
    }

    /// A device proxy bound to this device's stored dispatch. Cheap; call per use.
    fn device(self: *Device) vk.DeviceProxy {
        return vk.DeviceProxy.init(self.device_handle, &self.vkd);
    }

    /// An instance proxy bound to this device's stored dispatch.
    fn instanceProxy(self: *Device) vk.InstanceProxy {
        return vk.InstanceProxy.init(self.instance_handle, &self.vki);
    }

    /// Destroy the logical device, instance, and close the loader.
    pub fn deinit(self: *Device) void {
        self.device().destroyDevice(null);
        self.instanceProxy().destroyInstance(null);
        self.loader.close();
    }

    /// Create a device-local colour image + view sized/typed by `desc`. Caller frees
    /// via `Texture.deinit`. Errors: image/view/memory creation, `error.OutOfMemory`.
    pub fn createTexture(self: *Device, desc: port.TextureDesc) !Texture {
        const d = self.device();
        const format = formatToVk(desc.format);
        var usage: vk.ImageUsageFlags = .{};
        if (desc.usage.color_attachment) usage.color_attachment_bit = true;
        if (desc.usage.transfer_src) usage.transfer_src_bit = true;
        // ADR 0031 §4: a sprite atlas is uploaded (transfer dst) then sampled (sampled).
        if (desc.usage.transfer_dst) usage.transfer_dst_bit = true;
        if (desc.usage.sampled) usage.sampled_bit = true;

        const image = try d.createImage(&.{
            .image_type = .@"2d",
            .format = format,
            .extent = .{ .width = desc.width, .height = desc.height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .optimal,
            .usage = usage,
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        }, null);
        errdefer d.destroyImage(image, null);
        const reqs = d.getImageMemoryRequirements(image);
        const memory = try d.allocateMemory(&.{
            .allocation_size = reqs.size,
            .memory_type_index = try memoryType(self.mem_props, reqs.memory_type_bits, .{ .device_local_bit = true }),
        }, null);
        errdefer d.freeMemory(memory, null);
        try d.bindImageMemory(image, memory, 0);

        const view = try d.createImageView(&.{
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = full_range,
        }, null);
        return .{ .image = image, .view = view, .memory = memory, .width = desc.width, .height = desc.height, .format = format };
    }

    /// Create a host-visible, host-coherent buffer sized/typed by `desc`. Caller frees
    /// via `Buffer.deinit`. Errors: buffer/memory creation, `error.OutOfMemory`.
    pub fn createBuffer(self: *Device, desc: port.BufferDesc) !Buffer {
        const d = self.device();
        var usage: vk.BufferUsageFlags = .{};
        if (desc.usage.vertex) usage.vertex_buffer_bit = true;
        if (desc.usage.transfer_dst) usage.transfer_dst_bit = true;

        const buffer = try d.createBuffer(&.{ .size = desc.size, .usage = usage, .sharing_mode = .exclusive }, null);
        errdefer d.destroyBuffer(buffer, null);
        const reqs = d.getBufferMemoryRequirements(buffer);
        const memory = try d.allocateMemory(&.{
            .allocation_size = reqs.size,
            .memory_type_index = try memoryType(self.mem_props, reqs.memory_type_bits, .{ .host_visible_bit = true, .host_coherent_bit = true }),
        }, null);
        errdefer d.freeMemory(memory, null);
        try d.bindBufferMemory(buffer, memory, 0);
        return .{ .buffer = buffer, .memory = memory, .size = desc.size };
    }

    /// Build the scene graphics pipeline (dynamic rendering, `port.Vertex` input)
    /// targeting `format`. Caller frees via `Pipeline.deinit`. Errors: shader/layout/
    /// pipeline creation.
    // Over the ~60-line soft limit by design: the body is one flat
    // `GraphicsPipelineCreateInfo` literal (inherent Vulkan boilerplate); splitting it
    // would only make the single descriptor more artificial.
    pub fn createScenePipeline(self: *Device, format: port.TextureFormat) !Pipeline {
        const d = self.device();
        const module = try d.createShaderModule(&.{ .code_size = scene_spv.len, .p_code = @ptrCast(&scene_spv) }, null);
        defer d.destroyShaderModule(module, null);
        const stages = [_]vk.PipelineShaderStageCreateInfo{
            .{ .stage = .{ .vertex_bit = true }, .module = module, .p_name = "vs_main" },
            .{ .stage = .{ .fragment_bit = true }, .module = module, .p_name = "fs_main" },
        };
        const layout = try d.createPipelineLayout(&.{}, null);
        errdefer d.destroyPipelineLayout(layout, null);

        const binding: vk.VertexInputBindingDescription = .{ .binding = 0, .stride = @sizeOf(port.Vertex), .input_rate = .vertex };
        const attributes = [_]vk.VertexInputAttributeDescription{
            .{ .location = 0, .binding = 0, .format = .r32g32_sfloat, .offset = 0 },
            .{ .location = 1, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(port.Vertex, "r") },
        };
        const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
        const blend_attachment: vk.PipelineColorBlendAttachmentState = .{
            .blend_enable = .false,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .zero,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .zero,
            .alpha_blend_op = .add,
            .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        };
        var color_format = formatToVk(format);
        var rendering_info: vk.PipelineRenderingCreateInfo = .{
            .s_type = .pipeline_rendering_create_info,
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachment_formats = @ptrCast(&color_format),
            .depth_attachment_format = .undefined,
            .stencil_attachment_format = .undefined,
        };
        const pipeline_ci: vk.GraphicsPipelineCreateInfo = .{
            .p_next = &rendering_info,
            .stage_count = stages.len,
            .p_stages = &stages,
            .p_vertex_input_state = &.{
                .vertex_binding_description_count = 1,
                .p_vertex_binding_descriptions = @ptrCast(&binding),
                .vertex_attribute_description_count = attributes.len,
                .p_vertex_attribute_descriptions = &attributes,
            },
            .p_input_assembly_state = &.{ .topology = .triangle_list, .primitive_restart_enable = .false },
            .p_viewport_state = &.{ .viewport_count = 1, .scissor_count = 1 },
            .p_rasterization_state = &.{
                .depth_clamp_enable = .false,
                .rasterizer_discard_enable = .false,
                .polygon_mode = .fill,
                .cull_mode = .{},
                .front_face = .counter_clockwise,
                .depth_bias_enable = .false,
                .depth_bias_constant_factor = 0,
                .depth_bias_clamp = 0,
                .depth_bias_slope_factor = 0,
                .line_width = 1,
            },
            .p_multisample_state = &.{
                .rasterization_samples = .{ .@"1_bit" = true },
                .sample_shading_enable = .false,
                .min_sample_shading = 0,
                .alpha_to_coverage_enable = .false,
                .alpha_to_one_enable = .false,
            },
            .p_color_blend_state = &.{
                .logic_op_enable = .false,
                .logic_op = .copy,
                .attachment_count = 1,
                .p_attachments = @ptrCast(&blend_attachment),
                .blend_constants = .{ 0, 0, 0, 0 },
            },
            .p_dynamic_state = &.{ .dynamic_state_count = dynamic_states.len, .p_dynamic_states = &dynamic_states },
            .layout = layout,
            .render_pass = .null_handle,
            .subpass = 0,
            .base_pipeline_index = -1,
        };
        var pipelines = [_]vk.Pipeline{.null_handle};
        _ = try d.createGraphicsPipelines(.null_handle, &.{pipeline_ci}, null, &pipelines);
        return .{ .pipeline = pipelines[0], .layout = layout };
    }

    /// Upload tightly-packed RGBA8 `rgba` into `tex` (ADR 0031 §4: a decoded sprite
    /// atlas reaching the GPU): stage the bytes in a host-visible buffer, copy them into
    /// the device-local image with `vkCmdCopyBufferToImage`, and leave the image in
    /// shader-read-only layout ready for the sprite pipeline to sample. `tex` must have
    /// been created with `transfer_dst` + `sampled` usage; `rgba.len` must equal
    /// `tex.width*tex.height*4`. Synchronous (submits and waits idle, like `submit`).
    /// Errors: buffer/memory creation, map failure, command/submit failures,
    /// `error.OutOfMemory`.
    pub fn uploadTexture(self: *Device, tex: *Texture, rgba: []const u8) !void {
        const d = self.device();
        const byte_len: u64 = @intCast(rgba.len);
        const staging = try d.createBuffer(&.{ .size = byte_len, .usage = .{ .transfer_src_bit = true }, .sharing_mode = .exclusive }, null);
        defer d.destroyBuffer(staging, null);
        const reqs = d.getBufferMemoryRequirements(staging);
        const memory = try d.allocateMemory(&.{
            .allocation_size = reqs.size,
            .memory_type_index = try memoryType(self.mem_props, reqs.memory_type_bits, .{ .host_visible_bit = true, .host_coherent_bit = true }),
        }, null);
        defer d.freeMemory(memory, null);
        try d.bindBufferMemory(staging, memory, 0);
        {
            const mapped = try d.mapMemory(memory, 0, byte_len, .{});
            defer d.unmapMemory(memory);
            const dst: [*]u8 = @ptrCast(mapped.?);
            @memcpy(dst[0..rgba.len], rgba);
        }

        var cmd = try self.beginCommands();
        defer cmd.deinit(self);
        transition(d, cmd.cmd, tex.image, .undefined, .transfer_dst_optimal, .{}, .{ .transfer_write_bit = true }, .{ .top_of_pipe_bit = true }, .{ .transfer_bit = true });
        d.cmdCopyBufferToImage(cmd.cmd, staging, tex.image, .transfer_dst_optimal, &.{.{
            .buffer_offset = 0,
            .buffer_row_length = 0,
            .buffer_image_height = 0,
            .image_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
            .image_offset = .{ .x = 0, .y = 0, .z = 0 },
            .image_extent = .{ .width = tex.width, .height = tex.height, .depth = 1 },
        }});
        transition(d, cmd.cmd, tex.image, .transfer_dst_optimal, .shader_read_only_optimal, .{ .transfer_write_bit = true }, .{ .shader_read_bit = true }, .{ .transfer_bit = true }, .{ .fragment_shader_bit = true });
        try self.submit(&cmd);
    }

    /// Build the textured sprite pipeline (ADR 0031 §4): a blend-enabled graphics
    /// pipeline (`port.TexturedVertex` input, dynamic rendering) whose fragment stage
    /// samples the bound atlas, plus its descriptor set layout (binding 0 = sampled
    /// image, binding 1 = sampler — how naga splits the WGSL), a nearest-filter sampler
    /// (pixel-art sheets), and one descriptor set allocated up front for
    /// `CommandList.bindTexture` to re-point. Caller frees via `TexturedPipeline.deinit`.
    /// Errors: shader/layout/sampler/pool/descriptor/pipeline creation.
    // Over the ~60-line soft limit by design: like `createScenePipeline`, the body is
    // one flat pipeline description plus the descriptor/sampler objects it needs, all
    // inherent Vulkan boilerplate; splitting it would only fragment one atomic setup.
    pub fn createTexturedPipeline(self: *Device, format: port.TextureFormat) !TexturedPipeline {
        const d = self.device();
        const module = try d.createShaderModule(&.{ .code_size = sprite_spv.len, .p_code = @ptrCast(&sprite_spv) }, null);
        defer d.destroyShaderModule(module, null);
        const stages = [_]vk.PipelineShaderStageCreateInfo{
            .{ .stage = .{ .vertex_bit = true }, .module = module, .p_name = "vs_main" },
            .{ .stage = .{ .fragment_bit = true }, .module = module, .p_name = "fs_main" },
        };

        const bindings = [_]vk.DescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptor_type = .sampled_image, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true } },
            .{ .binding = 1, .descriptor_type = .sampler, .descriptor_count = 1, .stage_flags = .{ .fragment_bit = true } },
        };
        const set_layout = try d.createDescriptorSetLayout(&.{ .binding_count = bindings.len, .p_bindings = &bindings }, null);
        errdefer d.destroyDescriptorSetLayout(set_layout, null);

        const sampler = try d.createSampler(&.{
            .mag_filter = .nearest,
            .min_filter = .nearest,
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .mip_lod_bias = 0,
            .anisotropy_enable = .false,
            .max_anisotropy = 1,
            .compare_enable = .false,
            .compare_op = .always,
            .min_lod = 0,
            .max_lod = 0,
            .border_color = .int_opaque_black,
            .unnormalized_coordinates = .false,
        }, null);
        errdefer d.destroySampler(sampler, null);

        const pool_sizes = [_]vk.DescriptorPoolSize{
            .{ .type = .sampled_image, .descriptor_count = 1 },
            .{ .type = .sampler, .descriptor_count = 1 },
        };
        const pool = try d.createDescriptorPool(&.{ .max_sets = 1, .pool_size_count = pool_sizes.len, .p_pool_sizes = &pool_sizes }, null);
        errdefer d.destroyDescriptorPool(pool, null);
        var set: vk.DescriptorSet = .null_handle;
        try d.allocateDescriptorSets(&.{ .descriptor_pool = pool, .descriptor_set_count = 1, .p_set_layouts = @ptrCast(&set_layout) }, @ptrCast(&set));

        const layout = try d.createPipelineLayout(&.{ .set_layout_count = 1, .p_set_layouts = @ptrCast(&set_layout) }, null);
        errdefer d.destroyPipelineLayout(layout, null);

        const binding: vk.VertexInputBindingDescription = .{ .binding = 0, .stride = @sizeOf(port.TexturedVertex), .input_rate = .vertex };
        const attributes = [_]vk.VertexInputAttributeDescription{
            .{ .location = 0, .binding = 0, .format = .r32g32_sfloat, .offset = 0 },
            .{ .location = 1, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(port.TexturedVertex, "u") },
            .{ .location = 2, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(port.TexturedVertex, "r") },
        };
        const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
        // Straight-alpha "over" blend (ADR 0031 §2): sprites carry transparency.
        const blend_attachment: vk.PipelineColorBlendAttachmentState = .{
            .blend_enable = .true,
            .src_color_blend_factor = .src_alpha,
            .dst_color_blend_factor = .one_minus_src_alpha,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .one_minus_src_alpha,
            .alpha_blend_op = .add,
            .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        };
        var color_format = formatToVk(format);
        var rendering_info: vk.PipelineRenderingCreateInfo = .{
            .s_type = .pipeline_rendering_create_info,
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachment_formats = @ptrCast(&color_format),
            .depth_attachment_format = .undefined,
            .stencil_attachment_format = .undefined,
        };
        const pipeline_ci: vk.GraphicsPipelineCreateInfo = .{
            .p_next = &rendering_info,
            .stage_count = stages.len,
            .p_stages = &stages,
            .p_vertex_input_state = &.{
                .vertex_binding_description_count = 1,
                .p_vertex_binding_descriptions = @ptrCast(&binding),
                .vertex_attribute_description_count = attributes.len,
                .p_vertex_attribute_descriptions = &attributes,
            },
            .p_input_assembly_state = &.{ .topology = .triangle_list, .primitive_restart_enable = .false },
            .p_viewport_state = &.{ .viewport_count = 1, .scissor_count = 1 },
            .p_rasterization_state = &.{
                .depth_clamp_enable = .false,
                .rasterizer_discard_enable = .false,
                .polygon_mode = .fill,
                .cull_mode = .{},
                .front_face = .counter_clockwise,
                .depth_bias_enable = .false,
                .depth_bias_constant_factor = 0,
                .depth_bias_clamp = 0,
                .depth_bias_slope_factor = 0,
                .line_width = 1,
            },
            .p_multisample_state = &.{
                .rasterization_samples = .{ .@"1_bit" = true },
                .sample_shading_enable = .false,
                .min_sample_shading = 0,
                .alpha_to_coverage_enable = .false,
                .alpha_to_one_enable = .false,
            },
            .p_color_blend_state = &.{
                .logic_op_enable = .false,
                .logic_op = .copy,
                .attachment_count = 1,
                .p_attachments = @ptrCast(&blend_attachment),
                .blend_constants = .{ 0, 0, 0, 0 },
            },
            .p_dynamic_state = &.{ .dynamic_state_count = dynamic_states.len, .p_dynamic_states = &dynamic_states },
            .layout = layout,
            .render_pass = .null_handle,
            .subpass = 0,
            .base_pipeline_index = -1,
        };
        var pipelines = [_]vk.Pipeline{.null_handle};
        _ = try d.createGraphicsPipelines(.null_handle, &.{pipeline_ci}, null, &pipelines);
        return .{ .pipeline = pipelines[0], .layout = layout, .set_layout = set_layout, .sampler = sampler, .pool = pool, .set = set };
    }

    /// Allocate a primary command buffer (in its own pool) and begin recording it.
    /// Caller ends the recording via `submit` and frees via `CommandList.deinit`.
    /// Errors: pool/buffer allocation, begin failure.
    pub fn beginCommands(self: *Device) !CommandList {
        const d = self.device();
        const pool = try d.createCommandPool(&.{ .queue_family_index = self.family }, null);
        errdefer d.destroyCommandPool(pool, null);
        var cmd: vk.CommandBuffer = undefined;
        try d.allocateCommandBuffers(&.{ .command_pool = pool, .level = .primary, .command_buffer_count = 1 }, @ptrCast(&cmd));
        try d.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit_bit = true } });
        return .{ .dev = self, .pool = pool, .cmd = cmd };
    }

    /// End recording, submit `cmd` to the graphics queue, and wait for it to finish
    /// (offscreen render is synchronous). Errors: end/submit/wait failures.
    pub fn submit(self: *Device, cmd: *CommandList) !void {
        const d = self.device();
        try d.endCommandBuffer(cmd.cmd);
        const info: vk.SubmitInfo = .{ .command_buffer_count = 1, .p_command_buffers = @ptrCast(&cmd.cmd) };
        try d.queueSubmit(self.queue, &.{info}, .null_handle);
        try d.queueWaitIdle(self.queue);
    }

    /// Create a presentation swapchain over `desc.surface` (ADR 0012): build a
    /// `VkSurfaceKHR` from the opaque `SDL_Window*` (`SDL_Vulkan_CreateSurface`), then a
    /// `VkSwapchainKHR` (format/present-mode chosen from `desc`, `fifo` = vsync). Only a
    /// windowed (SDL3-linked) build can create one — a vulkan-only build has no window
    /// system, so it returns `error.NotImplemented` (the `enable_sdl3`-false branch is
    /// the only one compiled then, so no SDL symbol is referenced or linked). Caller
    /// frees via `Swapchain.deinit`. Errors: `error.NotImplemented`, `error.NoSurfaceHandle`,
    /// `error.SdlCreateSurface`, `error.NoPresentQueue`, plus surface/swapchain creation.
    pub fn createSwapchain(self: *Device, desc: port.SwapchainDesc) !Swapchain {
        if (build_options.enable_sdl3) {
            const window = desc.surface.native orelse return error.NoSurfaceHandle;
            var surface: vk.SurfaceKHR = .null_handle;
            if (!SDL_Vulkan_CreateSurface(window, self.instance_handle, null, &surface))
                return error.SdlCreateSurface;
            errdefer self.instanceProxy().destroySurfaceKHR(surface, null);

            // The graphics queue must be able to present to this surface. On the desktop
            // GPUs this bring-up targets, the graphics family also presents; a separate
            // present-queue selection is deferred (ADR 0012 §7) until a device needs it.
            const present_ok = try self.instanceProxy().getPhysicalDeviceSurfaceSupportKHR(self.pdev, self.family, surface);
            if (present_ok != .true) return error.NoPresentQueue;

            const parts = try buildChain(self, surface, desc.format, desc.present_mode, desc.width, desc.height, .null_handle);
            errdefer destroyChain(self, parts.images, parts.handle);

            const fence = try self.device().createFence(&.{}, null);
            return .{
                .surface = surface,
                .handle = parts.handle,
                .format = parts.format,
                .color_space = parts.color_space,
                .present_mode = parts.present_mode,
                .port_format = desc.format,
                .requested_mode = desc.present_mode,
                .extent = parts.extent,
                .images = parts.images,
                .acquire_fence = fence,
                .current = 0,
            };
        } else {
            // Vulkan-only build (no SDL3 linked): there is no window system to build a
            // surface from, so the present path is unavailable. `_ = &desc` marks the
            // parameter used on this comptime branch without a pointless discard on the
            // other (where it *is* used).
            _ = &desc;
            return error.NotImplemented;
        }
    }
};

/// The Vulkan objects a swapchain (re)creation produces, shared by `createSwapchain`
/// and `Swapchain.resize`. Pure Vulkan (no SDL) — the surface it renders onto is
/// created once, up front, and reused across recreations. Owns nothing on return; the
/// caller (`Swapchain`) takes ownership of `handle`/`images`.
const ChainParts = struct {
    handle: vk.SwapchainKHR,
    format: vk.Format,
    color_space: vk.ColorSpaceKHR,
    present_mode: vk.PresentModeKHR,
    extent: vk.Extent2D,
    /// Per-image render targets: swapchain-owned `image` (never destroyed by us; freed
    /// by `destroySwapchainKHR`) + a `view` we own, `memory = .null_handle`.
    images: []Texture,
};

/// Map the port's present mode to its Vulkan enum. `fifo` (vsync) is the only mode
/// Vulkan guarantees; the caller falls back to it when a requested mode is absent.
fn presentModeToVk(m: port.PresentMode) vk.PresentModeKHR {
    return switch (m) {
        .fifo => .fifo_khr,
        .mailbox => .mailbox_khr,
        .immediate => .immediate_khr,
    };
}

/// Build a `VkSwapchainKHR` and its per-image views over `surface`, choosing the
/// surface format (prefer `port_format`, else the surface's first), present mode
/// (prefer `requested`, else `fifo`), extent (the surface's current extent, else the
/// `width`/`height` request clamped to caps), and image count (`minImageCount + 1`).
/// `old` is passed as `oldSwapchain` for driver resource reuse (`.null_handle` on
/// first build). `dev`'s allocator owns the returned `images` slice. On error every
/// object created here is released before returning. Errors: surface capability/format/
/// present-mode queries, swapchain/image-view creation, `error.NoSurfaceFormat`,
/// `error.OutOfMemory`.
// Over the ~60-line soft limit by design: swapchain creation is one atomic operation —
// capabilities/format/present-mode negotiation, then chain + per-image view creation
// with matched error cleanup. Splitting it would scatter the negotiation from the
// creation it feeds without cutting the boilerplate.
fn buildChain(
    dev: *Device,
    surface: vk.SurfaceKHR,
    port_format: port.TextureFormat,
    requested: port.PresentMode,
    width: u32,
    height: u32,
    old: vk.SwapchainKHR,
) !ChainParts {
    const d = dev.device();
    const inst = dev.instanceProxy();
    const caps = try inst.getPhysicalDeviceSurfaceCapabilitiesKHR(dev.pdev, surface);

    // Surface format: prefer the port's format; else the surface's first advertised.
    const wanted = formatToVk(port_format);
    const formats = try inst.getPhysicalDeviceSurfaceFormatsAllocKHR(dev.pdev, surface, dev.gpa);
    defer dev.gpa.free(formats);
    if (formats.len == 0) return error.NoSurfaceFormat;
    var chosen = formats[0];
    for (formats) |f| {
        if (f.format == wanted) {
            chosen = f;
            break;
        }
    }

    // Present mode: prefer the requested mode; fall back to FIFO (always available).
    const want_mode = presentModeToVk(requested);
    const modes = try inst.getPhysicalDeviceSurfacePresentModesAllocKHR(dev.pdev, surface, dev.gpa);
    defer dev.gpa.free(modes);
    var mode: vk.PresentModeKHR = .fifo_khr;
    for (modes) |m| {
        if (m == want_mode) {
            mode = want_mode;
            break;
        }
    }

    // Extent: the surface's current extent when defined (0xFFFFFFFF means "the app
    // chooses"), else the requested size clamped to the surface's allowed range.
    const extent: vk.Extent2D = if (caps.current_extent.width != 0xFFFF_FFFF)
        caps.current_extent
    else
        .{
            .width = std.math.clamp(width, caps.min_image_extent.width, caps.max_image_extent.width),
            .height = std.math.clamp(height, caps.min_image_extent.height, caps.max_image_extent.height),
        };

    var image_count = caps.min_image_count + 1;
    if (caps.max_image_count != 0 and image_count > caps.max_image_count) image_count = caps.max_image_count;

    const handle = try d.createSwapchainKHR(&.{
        .surface = surface,
        .min_image_count = image_count,
        .image_format = chosen.format,
        .image_color_space = chosen.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true },
        .image_sharing_mode = .exclusive,
        .pre_transform = caps.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = mode,
        .clipped = .true,
        .old_swapchain = old,
    }, null);
    errdefer d.destroySwapchainKHR(handle, null);

    const vk_images = try d.getSwapchainImagesAllocKHR(handle, dev.gpa);
    defer dev.gpa.free(vk_images);
    const images = try dev.gpa.alloc(Texture, vk_images.len);
    errdefer dev.gpa.free(images);
    var made: usize = 0;
    errdefer for (images[0..made]) |*t| d.destroyImageView(t.view, null);
    for (vk_images, 0..) |img, i| {
        const view = try d.createImageView(&.{
            .image = img,
            .view_type = .@"2d",
            .format = chosen.format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = full_range,
        }, null);
        images[i] = .{ .image = img, .view = view, .memory = .null_handle, .width = extent.width, .height = extent.height, .format = chosen.format };
        made = i + 1;
    }

    return .{ .handle = handle, .format = chosen.format, .color_space = chosen.color_space, .present_mode = mode, .extent = extent, .images = images };
}

/// Release a chain built by `buildChain`: destroy the image views we own (never the
/// swapchain images themselves — `destroySwapchainKHR` owns those), free the `images`
/// slice, then destroy the swapchain. The surface outlives this and is freed by
/// `Swapchain.deinit`.
fn destroyChain(dev: *Device, images: []Texture, handle: vk.SwapchainKHR) void {
    const d = dev.device();
    for (images) |*t| d.destroyImageView(t.view, null);
    dev.gpa.free(images);
    d.destroySwapchainKHR(handle, null);
}

/// One acquired swapchain image for the frame being rendered (ADR 0012). `target` is
/// the acquired image (record the shared `CommandList` into it, then `present`);
/// borrowed — valid until the matching `present`. `status` mirrors the null backend so
/// the driver is backend-agnostic. On `.out_of_date` the surface must be recreated
/// before rendering, and `target` points at a still-valid image but must not be used.
pub const Frame = struct {
    /// The swapchain image to render into this frame.
    target: *Texture,
    /// Index of the acquired image in the swapchain.
    index: u32,
    /// Whether the acquired image is optimal for the surface.
    status: port.AcquireStatus,
};

/// A Vulkan presentation swapchain (`VkSwapchainKHR` over a `VkSurfaceKHR`) driving the
/// acquire → render → present loop with resize/out-of-date recreation (ADR 0012),
/// matching the null backend's surface. Synchronous by design for this bring-up: acquire
/// waits on a fence and rendering is submitted with `queueWaitIdle` (mirroring the
/// offscreen `Device.submit`), so present needs no wait semaphore. Multi-frame-in-flight
/// pipelining (per-image semaphores) is a deferred optimisation (ADR 0012 §7), internal
/// to this type when it lands. Built by `Device.createSwapchain`; owns its surface,
/// swapchain handle, per-image views, and one acquire fence.
pub const Swapchain = struct {
    /// The presentation surface built from the window (owned; freed in `deinit`).
    surface: vk.SurfaceKHR,
    /// The current swapchain handle (recreated by `resize`).
    handle: vk.SwapchainKHR,
    /// The chosen surface image format and colour space.
    format: vk.Format,
    color_space: vk.ColorSpaceKHR,
    /// The active present mode (the requested one, or FIFO if it was unavailable).
    present_mode: vk.PresentModeKHR,
    /// The port-level create parameters, retained so `resize` rebuilds consistently.
    port_format: port.TextureFormat,
    requested_mode: port.PresentMode,
    /// The current drawable extent in pixels.
    extent: vk.Extent2D,
    /// Per-image render targets (swapchain-owned images + our views).
    images: []Texture,
    /// Signalled by `acquire`; waited on then reset each frame (synchronous acquire).
    acquire_fence: vk.Fence,
    /// Index of the most recently acquired image.
    current: u32,

    /// Destroy the acquire fence, per-image views, swapchain, and surface. `dev` owns
    /// the GPU objects. Waits for the device to idle first so nothing is in use.
    pub fn deinit(self: *Swapchain, dev: *Device) void {
        const d = dev.device();
        // Idle so nothing is in use before destroy (a caller may deinit right after
        // `acquire`). On teardown a failed idle-wait is unrecoverable and changes nothing
        // we release — the same objects are destroyed regardless — and `deinit` has no
        // error channel, so the error is logged (not discarded — Zig 0.16 rejects a bare
        // `_ = err`, and CLAUDE.md bans `catch {}`) and teardown proceeds.
        d.deviceWaitIdle() catch |err|
            std.log.scoped(.gpu).debug("swapchain deinit: deviceWaitIdle failed ({s}); destroying anyway", .{@errorName(err)});
        d.destroyFence(self.acquire_fence, null);
        destroyChain(dev, self.images, self.handle);
        dev.instanceProxy().destroySurfaceKHR(self.surface, null);
    }

    /// Acquire the next image to render into (`vkAcquireNextImageKHR`). Signals the
    /// acquire fence, waits on it (so the image is ready when the caller records), and
    /// returns the image as a `Frame` with a translated `AcquireStatus`. On
    /// `VK_ERROR_OUT_OF_DATE_KHR` it returns `status = .out_of_date` (never a Zig error —
    /// ADR 0012 models it as a status enum) with `target` at the current image; the
    /// caller must `resize` before rendering. Errors: acquire/wait/reset failures other
    /// than out-of-date.
    pub fn acquire(self: *Swapchain, dev: *Device) !Frame {
        const d = dev.device();
        const timeout: u64 = std.math.maxInt(u64);
        const res = d.acquireNextImageKHR(self.handle, timeout, .null_handle, self.acquire_fence) catch |err| switch (err) {
            error.OutOfDateKHR => return .{ .target = &self.images[self.current], .index = self.current, .status = .out_of_date },
            else => return err,
        };
        self.current = res.image_index;
        _ = try d.waitForFences(&.{self.acquire_fence}, .true, timeout);
        try d.resetFences(&.{self.acquire_fence});
        const status: port.AcquireStatus = switch (res.result) {
            .suboptimal_khr => .suboptimal,
            else => .optimal,
        };
        return .{ .target = &self.images[res.image_index], .index = res.image_index, .status = status };
    }

    /// Present `frame` (`vkQueuePresentKHR`). Transitions the rendered image to
    /// `PRESENT_SRC` (its own one-time submission, so the shared render `CommandList`
    /// stays swapchain-agnostic), then queues it for display. Returns the translated
    /// `AcquireStatus`: `.suboptimal`/`.out_of_date` ask the caller to recreate. Assumes
    /// `frame` came from this swapchain's `acquire` and its image was already rendered
    /// (submitted with `queueWaitIdle`, so no wait semaphore is needed). Errors:
    /// transition submit / present failures other than out-of-date.
    pub fn present(self: *Swapchain, dev: *Device, frame: Frame) !port.AcquireStatus {
        const d = dev.device();
        var cmd = try dev.beginCommands();
        defer cmd.deinit(dev);
        transition(d, cmd.cmd, self.images[frame.index].image, .color_attachment_optimal, .present_src_khr, .{ .color_attachment_write_bit = true }, .{}, .{ .color_attachment_output_bit = true }, .{ .bottom_of_pipe_bit = true });
        try dev.submit(&cmd);

        const present_info: vk.PresentInfoKHR = .{
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&self.handle),
            .p_image_indices = @ptrCast(&frame.index),
        };
        const res = d.queuePresentKHR(dev.queue, &present_info) catch |err| switch (err) {
            error.OutOfDateKHR => return .out_of_date,
            else => return err,
        };
        return switch (res) {
            .suboptimal_khr => .suboptimal,
            else => .optimal,
        };
    }

    /// Recreate the swapchain for a new drawable size (on resize / out-of-date). Idles
    /// the device, builds a fresh chain (reusing the surface and the old handle as
    /// `oldSwapchain`), then destroys the old chain. The surface and acquire fence are
    /// retained. Errors: `deviceWaitIdle`, plus any `buildChain` failure (the old chain
    /// is left intact on failure).
    pub fn resize(self: *Swapchain, dev: *Device, width: u32, height: u32) !void {
        try dev.device().deviceWaitIdle();
        const parts = try buildChain(dev, self.surface, self.port_format, self.requested_mode, width, height, self.handle);
        destroyChain(dev, self.images, self.handle);
        self.handle = parts.handle;
        self.format = parts.format;
        self.color_space = parts.color_space;
        self.present_mode = parts.present_mode;
        self.extent = parts.extent;
        self.images = parts.images;
        self.current = 0;
    }
};

// Compile-time surface parity with the null backend (ADR 0012): the two backends'
// present surfaces must stay method-for-method compatible, but headless CI can only
// *run* the null one — so lock the shape here, checked whenever the flagged build
// (`-Denable-vulkan`) compiles this module. Importing the null backend is within the
// `gpu` module (no DAG crossing); `@hasDecl`/`@hasField` don't force analysis of the
// referenced bodies, so this stays a cheap, GPU-free assertion.
const null_backend = @import("../null/backend.zig");
comptime {
    for (.{ "createSwapchain", "createTexturedPipeline", "uploadTexture" }) |name| {
        if (!@hasDecl(Device, name) or !@hasDecl(null_backend.Device, name))
            @compileError("gpu surface drift: Device." ++ name);
    }
    // Sprite draw surface (ADR 0031 §4): both backends' command lists must offer the
    // textured-pipeline and texture binds `gpu.renderFrame` records.
    for (.{ "bindTexturedPipeline", "bindTexture" }) |name| {
        if (!@hasDecl(CommandList, name) or !@hasDecl(null_backend.CommandList, name))
            @compileError("sprite surface drift: CommandList." ++ name);
    }
    for (.{ "acquire", "present", "resize", "deinit" }) |name| {
        if (!@hasDecl(Swapchain, name) or !@hasDecl(null_backend.Swapchain, name))
            @compileError("swapchain surface drift: Swapchain." ++ name);
    }
    for (std.meta.fieldNames(Frame)) |name| {
        if (!@hasField(null_backend.Frame, name))
            @compileError("Frame field absent from null backend: " ++ name);
    }
}

fn graphicsFamily(instance: vk.InstanceProxy, pdev: vk.PhysicalDevice, gpa: Allocator) !u32 {
    const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdev, gpa);
    defer gpa.free(families);
    for (families, 0..) |f, i| {
        if (f.queue_flags.graphics_bit) return @intCast(i);
    }
    return error.NoGraphicsQueue;
}

fn memoryType(props: vk.PhysicalDeviceMemoryProperties, type_bits: u32, flags: vk.MemoryPropertyFlags) !u32 {
    for (props.memory_types[0..props.memory_type_count], 0..) |mt, i| {
        const usable = type_bits & (@as(u32, 1) << @intCast(i)) != 0;
        if (usable and mt.property_flags.contains(flags)) return @intCast(i);
    }
    return error.NoSuitableMemory;
}

fn transition(
    dev: vk.DeviceProxy,
    cmd: vk.CommandBuffer,
    image: vk.Image,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    src_access: vk.AccessFlags,
    dst_access: vk.AccessFlags,
    src_stage: vk.PipelineStageFlags,
    dst_stage: vk.PipelineStageFlags,
) void {
    const barrier: vk.ImageMemoryBarrier = .{
        .src_access_mask = src_access,
        .dst_access_mask = dst_access,
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = full_range,
    };
    dev.cmdPipelineBarrier(cmd, src_stage, dst_stage, .{}, null, null, &.{barrier});
}
