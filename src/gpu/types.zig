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

/// A textured, tinted sprite quad in normalized device coordinates (ADR 0031 §4;
/// issue #113 phase 2b): a quad that samples a sub-rect of the bound sprite atlas
/// instead of drawing a flat colour. The engine builds these from `Sprite` entities
/// (`render.projectSprites`); both backends sample the atlas at the per-vertex UVs and
/// multiply by `tint` — the Vulkan textured pipeline on the GPU, the null backend via its
/// CPU nearest-neighbour textured rasterizer (a real, headless test double).
pub const SpriteQuad = struct {
    /// Centre in NDC.
    center: [2]f32,
    /// Half-extent in NDC (x, y) *before* rotation.
    half: [2]f32,
    /// Atlas UV of the frame's top-left corner (u, v in 0..1).
    uv_min: [2]f32,
    /// Atlas UV of the frame's bottom-right corner (u, v in 0..1).
    uv_max: [2]f32,
    /// RGB tint multiplied with the sampled texel (white = untinted). Sourced from the
    /// entity's `Appearance.color` (ADR 0031 §1) so a frightened ghost can re-tint.
    tint: [3]f32 = .{ 1, 1, 1 },
    /// Rotation of the quad about its `center`, in radians (screen space, +x toward
    /// +y). `0` leaves the quad axis-aligned; used to face a directional sprite (Pac's
    /// wedge) along its travel direction. UVs are unrotated — only the corner positions
    /// rotate, so the sampled frame turns with the quad.
    angle: f32 = 0,
};
