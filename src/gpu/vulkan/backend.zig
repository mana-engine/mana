//! Vulkan gpu backend (ADR 0006), compiled only under `-Denable-vulkan`. M1 renders
//! offscreen — no window, no swapchain: it clears an image to a colour, copies it to
//! a host-visible buffer, and returns the RGBA pixels. The runtime turns those into a
//! PNG. Vulkan types stay inside this subtree; the engine-facing surface is plain
//! data. The loader (`vulkan-1`) is loaded dynamically at runtime, so no import
//! library / Vulkan SDK is needed at build time.

const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;

/// Vulkan API version this backend targets.
pub const target_api_version: u32 = @bitCast(vk.API_VERSION_1_2);

// The Vulkan loader is loaded dynamically at runtime (no import library / SDK
// needed). std.DynLib has no Windows implementation in Zig 0.16, so Windows goes
// through kernel32 directly; posix uses DynLib.
extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?windows.HMODULE;
extern "kernel32" fn GetProcAddress(module: windows.HMODULE, name: [*:0]const u8) callconv(.winapi) ?windows.FARPROC;
extern "kernel32" fn FreeLibrary(module: windows.HMODULE) callconv(.winapi) windows.BOOL;

const posix_loader_names = [_][]const u8{ "libvulkan.so.1", "libvulkan.so", "libvulkan.dylib", "libvulkan.1.dylib" };

/// A handle to the loaded Vulkan loader plus its `vkGetInstanceProcAddr`.
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

/// Render an `width`×`height` image cleared to `clear` (RGBA, 0..1) entirely on the
/// GPU and read it back. Returns tightly-packed RGBA8 pixels owned by `gpa`.
pub fn renderClear(gpa: Allocator, width: u32, height: u32, clear: [4]f32) ![]u8 {
    // --- Load the Vulkan loader dynamically ---------------------------------
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

    // --- Physical device + graphics queue family ----------------------------
    const pdevs = try instance.enumeratePhysicalDevicesAlloc(gpa);
    defer gpa.free(pdevs);
    if (pdevs.len == 0) return error.NoVulkanDevice;

    const pdev = pdevs[0];
    const family = try graphicsFamily(instance, pdev, gpa);
    const mem_props = instance.getPhysicalDeviceMemoryProperties(pdev);

    // --- Logical device + queue ---------------------------------------------
    const priority = [_]f32{1.0};
    const queue_ci: vk.DeviceQueueCreateInfo = .{
        .queue_family_index = family,
        .queue_count = 1,
        .p_queue_priorities = &priority,
    };
    const device_handle = try instance.createDevice(pdev, &.{
        .queue_create_info_count = 1,
        .p_queue_create_infos = @ptrCast(&queue_ci),
    }, null);
    var vkd = vk.DeviceWrapper.load(device_handle, vki.dispatch.vkGetDeviceProcAddr.?);
    const dev = vk.DeviceProxy.init(device_handle, &vkd);
    defer dev.destroyDevice(null);
    const queue = dev.getDeviceQueue(family, 0);

    // --- Offscreen colour image (device-local) ------------------------------
    const image = try dev.createImage(&.{
        .image_type = .@"2d",
        .format = .r8g8b8a8_unorm,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = .{ .transfer_src_bit = true, .transfer_dst_bit = true },
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

    // --- Host-visible readback buffer ---------------------------------------
    const size: u64 = @as(u64, width) * height * 4;
    const buffer = try dev.createBuffer(&.{
        .size = size,
        .usage = .{ .transfer_dst_bit = true },
        .sharing_mode = .exclusive,
    }, null);
    defer dev.destroyBuffer(buffer, null);

    const buf_reqs = dev.getBufferMemoryRequirements(buffer);
    const buf_mem = try dev.allocateMemory(&.{
        .allocation_size = buf_reqs.size,
        .memory_type_index = try memoryType(mem_props, buf_reqs.memory_type_bits, .{
            .host_visible_bit = true,
            .host_coherent_bit = true,
        }),
    }, null);
    defer dev.freeMemory(buf_mem, null);
    try dev.bindBufferMemory(buffer, buf_mem, 0);

    // --- Record: clear, then copy image → buffer ----------------------------
    const pool = try dev.createCommandPool(&.{ .queue_family_index = family }, null);
    defer dev.destroyCommandPool(pool, null);
    var cmd: vk.CommandBuffer = undefined;
    try dev.allocateCommandBuffers(&.{
        .command_pool = pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmd));

    const full_range: vk.ImageSubresourceRange = .{
        .aspect_mask = .{ .color_bit = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = 1,
    };

    try dev.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit_bit = true } });

    transition(dev, cmd, image, full_range, .undefined, .transfer_dst_optimal, .{}, .{ .transfer_write_bit = true }, .{ .top_of_pipe_bit = true }, .{ .transfer_bit = true });

    const clear_color: vk.ClearColorValue = .{ .float_32 = clear };
    dev.cmdClearColorImage(cmd, image, .transfer_dst_optimal, &clear_color, &.{full_range});

    transition(dev, cmd, image, full_range, .transfer_dst_optimal, .transfer_src_optimal, .{ .transfer_write_bit = true }, .{ .transfer_read_bit = true }, .{ .transfer_bit = true }, .{ .transfer_bit = true });

    const region: vk.BufferImageCopy = .{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{ .aspect_mask = .{ .color_bit = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = width, .height = height, .depth = 1 },
    };
    dev.cmdCopyImageToBuffer(cmd, image, .transfer_src_optimal, buffer, &.{region});

    try dev.endCommandBuffer(cmd);

    // --- Submit and wait ----------------------------------------------------
    const submit: vk.SubmitInfo = .{ .command_buffer_count = 1, .p_command_buffers = @ptrCast(&cmd) };
    try dev.queueSubmit(queue, &.{submit}, .null_handle);
    try dev.queueWaitIdle(queue);

    // --- Read back ----------------------------------------------------------
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
