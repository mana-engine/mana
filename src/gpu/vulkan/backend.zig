//! Vulkan gpu backend (ADR 0006), compiled only under `-Denable-vulkan`. Renders
//! offscreen — no window, no swapchain. `renderScene` (M3) draws a set of coloured
//! quads (NDC positions the engine iso-projected) through a graphics pipeline via
//! dynamic rendering, reads the image back, and returns RGBA8 pixels; the runtime
//! turns those into a PNG. Vulkan types stay inside this subtree; the engine-facing
//! surface is plain data. The loader (`vulkan-1`) is loaded dynamically at runtime,
//! so no import library / Vulkan SDK is needed.

const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const windows = std.os.windows;
const Quad = @import("../types.zig").Quad;
const Allocator = std.mem.Allocator;

/// Vulkan API version this backend targets (1.3 for core dynamic rendering).
pub const target_api_version: u32 = @bitCast(vk.API_VERSION_1_3);

/// Scene shaders, compiled from WGSL by naga (`mise run shaders`). Aligned to u32
/// so it can be handed to Vulkan directly.
const scene_spv align(@alignOf(u32)) = @embedFile("shaders/scene.spv").*;

/// One vertex as consumed by scene.wgsl: NDC position + RGB colour, tightly packed.
const Vertex = extern struct { x: f32, y: f32, r: f32, g: f32, b: f32 };

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

/// Draw `quads` into an `width`×`height` offscreen image on the GPU and read it
/// back. Returns tightly-packed RGBA8 pixels owned by `gpa`. `clear` is the
/// background colour (RGBA 0..1).
pub fn renderScene(gpa: Allocator, width: u32, height: u32, quads: []const Quad, clear: [4]f32) ![]u8 {
    var loader = Loader.open() orelse return error.VulkanLoaderNotFound;
    defer loader.close();
    const vkb = vk.BaseWrapper.load(loader.get_proc);

    // --- Instance -----------------------------------------------------------
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
    defer instance.destroyInstance(null);

    // --- Physical device + queue family -------------------------------------
    const pdevs = try instance.enumeratePhysicalDevicesAlloc(gpa);
    defer gpa.free(pdevs);
    if (pdevs.len == 0) return error.NoVulkanDevice;
    const pdev = pdevs[0];
    const family = try graphicsFamily(instance, pdev, gpa);
    const mem_props = instance.getPhysicalDeviceMemoryProperties(pdev);

    // --- Logical device (dynamic rendering enabled) + queue -----------------
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
    defer dev.destroyDevice(null);
    const queue = dev.getDeviceQueue(family, 0);

    const format: vk.Format = .r8g8b8a8_unorm;

    // --- Offscreen colour image + view --------------------------------------
    const image = try dev.createImage(&.{
        .image_type = .@"2d",
        .format = format,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = .{ .color_attachment_bit = true, .transfer_src_bit = true },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null);
    defer dev.destroyImage(image, null);
    const image_reqs = dev.getImageMemoryRequirements(image);
    const image_mem = try dev.allocateMemory(&.{
        .allocation_size = image_reqs.size,
        .memory_type_index = try memoryType(mem_props, image_reqs.memory_type_bits, .{ .device_local_bit = true }),
    }, null);
    defer dev.freeMemory(image_mem, null);
    try dev.bindImageMemory(image, image_mem, 0);

    const full_range: vk.ImageSubresourceRange = .{
        .aspect_mask = .{ .color_bit = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = 1,
    };
    const view = try dev.createImageView(&.{
        .image = image,
        .view_type = .@"2d",
        .format = format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = full_range,
    }, null);
    defer dev.destroyImageView(view, null);

    // --- Host-visible readback buffer ---------------------------------------
    const size: u64 = @as(u64, width) * height * 4;
    const buffer = try dev.createBuffer(&.{ .size = size, .usage = .{ .transfer_dst_bit = true }, .sharing_mode = .exclusive }, null);
    defer dev.destroyBuffer(buffer, null);
    const buf_reqs = dev.getBufferMemoryRequirements(buffer);
    const buf_mem = try dev.allocateMemory(&.{
        .allocation_size = buf_reqs.size,
        .memory_type_index = try memoryType(mem_props, buf_reqs.memory_type_bits, .{ .host_visible_bit = true, .host_coherent_bit = true }),
    }, null);
    defer dev.freeMemory(buf_mem, null);
    try dev.bindBufferMemory(buffer, buf_mem, 0);

    // --- Vertex buffer (2 triangles per quad), host-visible -----------------
    const vertex_count: u32 = @intCast(quads.len * 6);
    var vbuf: vk.Buffer = .null_handle;
    var vbuf_mem: vk.DeviceMemory = .null_handle;
    defer if (vbuf_mem != .null_handle) dev.freeMemory(vbuf_mem, null);
    defer if (vbuf != .null_handle) dev.destroyBuffer(vbuf, null);
    if (vertex_count > 0) {
        const vbytes: u64 = @as(u64, vertex_count) * @sizeOf(Vertex);
        vbuf = try dev.createBuffer(&.{ .size = vbytes, .usage = .{ .vertex_buffer_bit = true }, .sharing_mode = .exclusive }, null);
        const vreqs = dev.getBufferMemoryRequirements(vbuf);
        vbuf_mem = try dev.allocateMemory(&.{
            .allocation_size = vreqs.size,
            .memory_type_index = try memoryType(mem_props, vreqs.memory_type_bits, .{ .host_visible_bit = true, .host_coherent_bit = true }),
        }, null);
        try dev.bindBufferMemory(vbuf, vbuf_mem, 0);

        const mapped = try dev.mapMemory(vbuf_mem, 0, vbytes, .{});
        const verts: [*]Vertex = @ptrCast(@alignCast(mapped.?));
        for (quads, 0..) |q, i| {
            const x0 = q.center[0] - q.half[0];
            const x1 = q.center[0] + q.half[0];
            const y0 = q.center[1] - q.half[1];
            const y1 = q.center[1] + q.half[1];
            const c = q.color;
            const base = i * 6;
            verts[base + 0] = .{ .x = x0, .y = y0, .r = c[0], .g = c[1], .b = c[2] };
            verts[base + 1] = .{ .x = x1, .y = y0, .r = c[0], .g = c[1], .b = c[2] };
            verts[base + 2] = .{ .x = x0, .y = y1, .r = c[0], .g = c[1], .b = c[2] };
            verts[base + 3] = .{ .x = x0, .y = y1, .r = c[0], .g = c[1], .b = c[2] };
            verts[base + 4] = .{ .x = x1, .y = y0, .r = c[0], .g = c[1], .b = c[2] };
            verts[base + 5] = .{ .x = x1, .y = y1, .r = c[0], .g = c[1], .b = c[2] };
        }
        dev.unmapMemory(vbuf_mem);
    }

    // --- Graphics pipeline (dynamic rendering, vertex input) ----------------
    const module = try dev.createShaderModule(&.{ .code_size = scene_spv.len, .p_code = @ptrCast(&scene_spv) }, null);
    defer dev.destroyShaderModule(module, null);
    const stages = [_]vk.PipelineShaderStageCreateInfo{
        .{ .stage = .{ .vertex_bit = true }, .module = module, .p_name = "vs_main" },
        .{ .stage = .{ .fragment_bit = true }, .module = module, .p_name = "fs_main" },
    };
    const layout = try dev.createPipelineLayout(&.{}, null);
    defer dev.destroyPipelineLayout(layout, null);

    const binding: vk.VertexInputBindingDescription = .{ .binding = 0, .stride = @sizeOf(Vertex), .input_rate = .vertex };
    const attributes = [_]vk.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32_sfloat, .offset = 0 },
        .{ .location = 1, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(Vertex, "r") },
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
    var color_format = format;
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
    _ = try dev.createGraphicsPipelines(.null_handle, &.{pipeline_ci}, null, &pipelines);
    const pipeline = pipelines[0];
    defer dev.destroyPipeline(pipeline, null);

    // --- Record: draw the quads, then copy image → buffer -------------------
    const pool = try dev.createCommandPool(&.{ .queue_family_index = family }, null);
    defer dev.destroyCommandPool(pool, null);
    var cmd: vk.CommandBuffer = undefined;
    try dev.allocateCommandBuffers(&.{ .command_pool = pool, .level = .primary, .command_buffer_count = 1 }, @ptrCast(&cmd));

    try dev.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit_bit = true } });
    transition(dev, cmd, image, full_range, .undefined, .color_attachment_optimal, .{}, .{ .color_attachment_write_bit = true }, .{ .top_of_pipe_bit = true }, .{ .color_attachment_output_bit = true });

    const color_attachment: vk.RenderingAttachmentInfo = .{
        .image_view = view,
        .image_layout = .color_attachment_optimal,
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
        .load_op = .clear,
        .store_op = .store,
        .clear_value = .{ .color = .{ .float_32 = clear } },
    };
    dev.cmdBeginRendering(cmd, &.{
        .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = width, .height = height } },
        .layer_count = 1,
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color_attachment),
    });
    dev.cmdBindPipeline(cmd, .graphics, pipeline);
    dev.cmdSetViewport(cmd, 0, &.{.{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height), .min_depth = 0, .max_depth = 1 }});
    dev.cmdSetScissor(cmd, 0, &.{.{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = width, .height = height } }});
    if (vertex_count > 0) {
        dev.cmdBindVertexBuffers(cmd, 0, &.{vbuf}, &.{0});
        dev.cmdDraw(cmd, vertex_count, 1, 0, 0);
    }
    dev.cmdEndRendering(cmd);

    transition(dev, cmd, image, full_range, .color_attachment_optimal, .transfer_src_optimal, .{ .color_attachment_write_bit = true }, .{ .transfer_read_bit = true }, .{ .color_attachment_output_bit = true }, .{ .transfer_bit = true });
    dev.cmdCopyImageToBuffer(cmd, image, .transfer_src_optimal, buffer, &.{.{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = width, .height = height, .depth = 1 },
    }});
    try dev.endCommandBuffer(cmd);

    const submit: vk.SubmitInfo = .{ .command_buffer_count = 1, .p_command_buffers = @ptrCast(&cmd) };
    try dev.queueSubmit(queue, &.{submit}, .null_handle);
    try dev.queueWaitIdle(queue);

    const mapped = try dev.mapMemory(buf_mem, 0, size, .{});
    defer dev.unmapMemory(buf_mem);
    const src: [*]const u8 = @ptrCast(mapped.?);
    return gpa.dupe(u8, src[0..@intCast(size)]);
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
    range: vk.ImageSubresourceRange,
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
        .subresource_range = range,
    };
    dev.cmdPipelineBarrier(cmd, src_stage, dst_stage, .{}, null, null, &.{barrier});
}
