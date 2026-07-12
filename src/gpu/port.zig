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
/// scene's colour target is a render target that is then copied to host memory.
pub const TextureUsage = packed struct {
    /// Rendered into as a colour attachment.
    color_attachment: bool = false,
    /// Copied from into a `Buffer` (readback).
    transfer_src: bool = false,
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
