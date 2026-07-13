//! Plain-data types the gpu port exposes to the engine — no Vulkan, present in
//! every build (including the null backend).

/// The silhouette a `Quad` draws as (ADR 0030 shape addendum). A small, genre-neutral
/// vocabulary — content (not `src/`) decides what a `rect` vs `circle` *means* (a wall
/// vs a pellet). `rect` is the default so an entity that declares no shape keeps the
/// original axis-aligned-square look byte-for-byte. Purely a render-time hint: the
/// gpu backend's quad rasterizer treats every variant as its bounding quad (no true
/// circle geometry yet); only the headless SVG emitter currently draws the distinct
/// silhouette (`render_svg.zig`).
pub const Shape = enum {
    rect,
    circle,
};

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
    /// Silhouette to draw (ADR 0030 shape addendum). Defaults to `.rect`, the
    /// pre-existing behavior.
    shape: Shape = .rect,
};
