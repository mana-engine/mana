//! Plain-data types the gpu port exposes to the engine — no Vulkan, present in
//! every build (including the null backend).

/// A screen-space, axis-aligned coloured quad in normalized device coordinates
/// (NDC: x,y in [-1, 1]). The engine builds these (e.g. by iso-projecting entity
/// transforms); the backend rasterizes them.
pub const Quad = struct {
    /// Centre in NDC.
    center: [2]f32,
    /// Half-extent in NDC (x, y).
    half: [2]f32,
    /// RGB colour, 0..1.
    color: [3]f32,
};
