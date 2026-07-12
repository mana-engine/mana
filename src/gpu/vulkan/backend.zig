//! Vulkan gpu backend (ADR 0006), compiled only under `-Denable-vulkan`. Renders
//! offscreen — no window, no swapchain. It implements the engine-owned port surface
//! (ADR 0010): a `Device` creates `Texture`/`Buffer`/`Pipeline` resources and a
//! `CommandList`, and the shared `gpu.renderScene` driver records draws + a readback
//! through them. Here those types are Vulkan handles (image/view/memory, buffer,
//! graphics pipeline, command buffer) driven via dynamic rendering; Vulkan types
//! stay inside this subtree — the port surface above is plain data. The loader
//! (`vulkan-1`) is loaded dynamically at runtime, so no import library / Vulkan SDK
//! is needed.
//!
//! Over the ~500-line soft limit by design: this is one irreducibly verbose Vulkan
//! backend — device/pipeline/command/barrier boilerplate — kept as a single unit
//! behind the `gpu` port. Splitting the handles across files would scatter tightly
//! coupled boilerplate without reducing it.

const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const windows = std.os.windows;
const port = @import("../port.zig");
const Allocator = std.mem.Allocator;

/// Vulkan API version this backend targets (1.3 for core dynamic rendering).
pub const target_api_version: u32 = @bitCast(vk.API_VERSION_1_3);

/// Scene shaders, compiled from WGSL by naga (`mise run shaders`). Aligned to u32
/// so it can be handed to Vulkan directly.
const scene_spv align(@alignOf(u32)) = @embedFile("shaders/scene.spv").*;

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

/// Records one submission's worth of commands into a primary command buffer, owning
/// the pool it was allocated from. Method shapes mirror the null backend so
/// `gpu.renderScene` is backend-agnostic.
pub const CommandList = struct {
    dev: *Device,
    pool: vk.CommandPool,
    cmd: vk.CommandBuffer,

    /// Transition `target` to colour-attachment layout and begin dynamic rendering,
    /// clearing to `clear` (RGBA, 0..1); also sets a full-image viewport and scissor.
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
        d.cmdSetViewport(self.cmd, 0, &.{.{ .x = 0, .y = 0, .width = @floatFromInt(target.width), .height = @floatFromInt(target.height), .min_depth = 0, .max_depth = 1 }});
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
        const instance_handle = try vkb.createInstance(&.{ .p_application_info = &app_info }, null);
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
        const device_handle = try instance.createDevice(pdev, &.{
            .p_next = &features13,
            .queue_create_info_count = 1,
            .p_queue_create_infos = @ptrCast(&queue_ci),
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

    /// Create a presentation swapchain over `desc.surface` (ADR 0012). Deferred: the
    /// real `VkSurfaceKHR`/`VkSwapchainKHR` bring-up (SDL_Vulkan_CreateSurface, image
    /// acquisition, present queue) lands with the supervised SDL3 windowing lane, so
    /// this backend only pins the interface today. Errors: `error.NotImplemented`.
    pub fn createSwapchain(self: *Device, desc: port.SwapchainDesc) !Swapchain {
        _ = self;
        _ = desc;
        return error.NotImplemented;
    }
};

/// One acquired swapchain image for the frame being rendered (ADR 0012). Method
/// shapes mirror the null backend so a future present driver is backend-agnostic.
pub const Frame = struct {
    /// The swapchain image to render into this frame.
    target: *Texture,
    /// Index of the acquired image in the swapchain.
    index: u32,
    /// Whether the acquired image is optimal for the surface.
    status: port.AcquireStatus,
};

/// A Vulkan presentation swapchain (`VkSwapchainKHR` over a `VkSurfaceKHR`). Deferred:
/// the real acquire/present/resize path is the supervised SDL3 windowing lane (ADR
/// 0012); this backend pins the interface so the shared surface stays in lockstep and
/// the flagged build compiles. Every method is currently `error.NotImplemented`.
pub const Swapchain = struct {
    /// Destroy the swapchain and surface. No-op until the real path lands.
    pub fn deinit(self: *Swapchain, dev: *Device) void {
        _ = self;
        _ = dev;
    }

    /// Acquire the next image (`vkAcquireNextImageKHR`). Deferred.
    /// Errors: `error.NotImplemented`.
    pub fn acquire(self: *Swapchain, dev: *Device) !Frame {
        _ = self;
        _ = dev;
        return error.NotImplemented;
    }

    /// Present `frame` (`vkQueuePresentKHR`). Deferred.
    /// Errors: `error.NotImplemented`.
    pub fn present(self: *Swapchain, dev: *Device, frame: Frame) !port.AcquireStatus {
        _ = self;
        _ = dev;
        _ = frame;
        return error.NotImplemented;
    }

    /// Recreate the swapchain for a new drawable size (on resize/out-of-date).
    /// Deferred. Errors: `error.NotImplemented`.
    pub fn resize(self: *Swapchain, dev: *Device, width: u32, height: u32) !void {
        _ = self;
        _ = dev;
        _ = width;
        _ = height;
        return error.NotImplemented;
    }
};

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
