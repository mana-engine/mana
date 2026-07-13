//! The engine-owned gpu port vocabulary (ADR 0010): the minimal set of resource
//! and command types the current renderer exercises — Texture, Buffer, Pipeline,
//! CommandList — expressed as **plain-data descriptors** with no Vulkan (or any
//! backend) types. Every backend (null, Vulkan) implements the same `Device`
//! surface over these descriptors; nothing here or above `gpu` sees a Vulkan type.
//!
//! Scope is deliberately tight (CLAUDE.md: "no speculative flexibility; pin only
//! the vocabulary the renderer actually needs"). The renderer draws one kind of
//! thing — coloured NDC quads through a single scene pipeline into one offscreen
//! colour target, read back to host memory — so the vocabulary covers exactly that
//! and nothing more. Widening it (new formats, depth, bind groups, …) is a later
//! ADR justified by a concrete renderer need.

/// Pixel format of a `Texture`. Only the offscreen colour target's format is used
/// today; `rgba8_unorm` matches the RGBA8 pixels the renderer reads back.
pub const TextureFormat = enum { rgba8_unorm };

/// How a `Texture` is used, so a backend can pick the right allocation/layout. The
/// scene's colour target is a render target then copied to host memory; a sprite sheet
/// (ADR 0031) is a `transfer_dst` (host→device upload) + `sampled` (read in a shader).
pub const TextureUsage = packed struct {
    /// Rendered into as a colour attachment.
    color_attachment: bool = false,
    /// Copied from into a `Buffer` (readback).
    transfer_src: bool = false,
    /// Copied into from host memory — the destination of `Device.uploadTexture`
    /// (ADR 0031: a decoded sprite sheet reaches the GPU).
    transfer_dst: bool = false,
    /// Read (sampled) in a fragment shader — a sprite-sheet texture (ADR 0031).
    sampled: bool = false,
};

/// How a `Buffer` is used. The renderer uses two: a host-written vertex buffer and
/// a readback buffer that receives the rendered image.
pub const BufferUsage = packed struct {
    /// Bound as vertex input to a draw.
    vertex: bool = false,
    /// Written by an image→buffer copy (readback destination).
    transfer_dst: bool = false,
};

/// Describes a `Texture` to create. Plain data; owns nothing.
pub const TextureDesc = struct {
    width: u32,
    height: u32,
    format: TextureFormat,
    usage: TextureUsage,
};

/// Describes a `Buffer` to create. `size` is in bytes. Buffers in the current
/// renderer are host-visible (written or read on the CPU); memory placement is not
/// yet part of the vocabulary because no resource needs a choice.
pub const BufferDesc = struct {
    size: u64,
    usage: BufferUsage,
};

/// One vertex as consumed by the scene pipeline: an NDC position and an RGB colour,
/// tightly packed. `extern` so its layout is stable for GPU vertex input; both
/// backends and the shared vertex builder agree on this single format.
pub const Vertex = extern struct {
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
};

// --- Presentation surface (ADR 0012) ---------------------------------------------
// A windowed present path: the `platform` port owns an OS window and hands `gpu` an
// OPAQUE native handle; `gpu` builds a `Swapchain` from it and drives
// acquire → render → present each real frame, recreating on resize. Only two impls
// justify this vocabulary (CLAUDE.md "second concrete impl planned, or don't
// abstract"): the null backend — a real, headless swapchain, implemented now — and
// the Vulkan backend — the next, supervised lane. Invariant #4 is preserved by
// keeping the handle opaque: it is a bare pointer here, never a `VkSurfaceKHR`; the
// Vulkan backend turns it into a surface internally (SDL_Vulkan_CreateSurface) and
// nothing above `gpu` ever sees a Vulkan type. The concrete `Swapchain`/`Frame`
// types are backend-owned (re-exported from `gpu.zig`, like `Device`); this file
// pins only the plain-data descriptors and status enums they share.

/// An opaque, engine-owned handle to a native OS window, supplied by the `platform`
/// port for a backend to build a presentation surface from. `native` is a pointer the
/// backend interprets per its adapter (e.g. an `SDL_Window*` under SDL3); code above
/// `gpu` never dereferences it, and it is deliberately NOT a `VkSurfaceKHR` — the
/// Vulkan surface is created and owned inside the Vulkan backend. `null` means no OS
/// window (the headless/null path), which the null backend's swapchain accepts.
/// Ownership/lifetime: the pointer is owned by the `platform` `Window`; it must
/// outlive any `Swapchain` built from it. `platform` and `gpu` never import each
/// other — `engine` (which imports both) wraps the window's opaque handle into this.
pub const SurfaceHandle = extern struct {
    native: ?*anyopaque = null,
};

/// How presented images are queued to the display. `fifo` is vsync and the only mode
/// guaranteed available (Vulkan `VK_PRESENT_MODE_FIFO_KHR`); `mailbox` is low-latency
/// vsync (triple-buffered); `immediate` is unsynchronized (may tear). A backend falls
/// back to `fifo` when a requested mode is unavailable.
pub const PresentMode = enum { fifo, mailbox, immediate };

/// Outcome of acquiring or presenting a swapchain image, mirroring Vulkan's
/// `VK_SUCCESS` / `VK_SUBOPTIMAL_KHR` / `VK_ERROR_OUT_OF_DATE_KHR`. `optimal` proceeds;
/// `suboptimal` still presents but signals the swapchain should be recreated soon;
/// `out_of_date` means the surface changed (e.g. window resize) and the caller must
/// `resize`/recreate before rendering again. The null backend only ever reports
/// `optimal`.
pub const AcquireStatus = enum { optimal, suboptimal, out_of_date };

/// Describes a `Swapchain` to create over a window surface. Plain data; borrows the
/// `surface` handle (see `SurfaceHandle` lifetime). `width`/`height` are the drawable
/// size in pixels; a backend re-derives them on `resize`. Owns nothing.
pub const SwapchainDesc = struct {
    surface: SurfaceHandle,
    width: u32,
    height: u32,
    format: TextureFormat,
    present_mode: PresentMode,
};
