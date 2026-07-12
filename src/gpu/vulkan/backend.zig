//! Vulkan gpu backend (ADR 0006), compiled only under `-Denable-vulkan`. Renders
//! offscreen — no window, no swapchain — into a host-readable image; the runtime
//! turns the returned RGBA pixels into a PNG. Vulkan types stay inside this
//! subtree; the engine-facing surface is plain data.

const std = @import("std");
const vk = @import("vulkan");

/// Vulkan API version this backend targets.
pub const target_api_version: u32 = @bitCast(vk.API_VERSION_1_3);
