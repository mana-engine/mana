//! Built-in engine components (ADR 0004 §3). These are genre-neutral spatial data
//! the engine's native systems operate on; game- or script-defined data components
//! are a deferred follow-on. Adding a built-in component here plus a column in
//! `World` and a system that uses it is the whole extension story.

const core = @import("core");
const physics = @import("physics");
const gpu = @import("gpu");

const Vec2 = core.Vec2;
const Vec3 = core.Vec3;

/// World-space placement of an entity. Room to grow (rotation, scale) later.
pub const Transform = struct { pos: Vec3 };

/// Per-tick world-space movement, integrated into `Transform.pos` by the movement
/// system.
pub const Velocity = struct { v: Vec3 };

/// Hit points. `current` is the live value in `[0, max]`; the regen system moves
/// `current` toward `max`. Genre-neutral: what damage/death mean is content's job.
pub const Health = struct { current: f32, max: f32 };

/// A named scalar data component as declared on an entity in ZON (ADR 0024):
/// `.{ .name = "score", .value = 0 }`. `name` identifies the data-component column
/// (registered in `World.data`); `value` is the Lua-number-compatible `f64` scalar
/// `mana.get`/`mana.set` read and write. Richer value types are a future ADR.
pub const NamedValue = struct {
    name: []const u8,
    value: f64,
};

/// A collision shape attached to an entity for the physics `collision` system
/// (ADR 0008). `shape` is a *local* collider placed at the entity's `Transform`
/// (collision is on the XY plane, 2.5D); `layers` filters which colliders may
/// interact; `is_static` marks immovable level geometry — two static colliders
/// never generate a collision event. An entity needs both a `Transform` and a
/// `Collider` to participate.
pub const Collider = struct {
    shape: physics.Shape,
    layers: physics.Layers = .{},
    is_static: bool = false,
};

/// Cosmetic per-entity render appearance (ADR 0030, shape addendum): what the
/// headless/GPU renderer draws instead of the palette-by-spawn-order fallback
/// (`render.default_palette`). `color` replaces the palette pick; `size` is the
/// entity's WORLD-space footprint (full width/height of its quad, in world units)
/// that `render.project` multiplies by the projection's pixels-per-world-unit scale
/// — so a wall on a one-unit grid cell (`size = 1`) fills its cell and a dot
/// (`size = 0.3`) stays small, regardless of the projection's pixel scale. `shape`
/// is the silhouette drawn within that footprint (`gpu.Shape`: `rect` default,
/// `circle`) — a small, genre-neutral vocabulary; what a shape *means* (a wall vs. a
/// pellet) is content's job, never `src/`. Purely a render-time hint: none of these
/// fields ever affect collision, pathfinding, or any other sim system, so `Appearance`
/// is excluded from `World.stateHash` like `Velocity`/`Controller`/`NavAgent`.
pub const Appearance = struct {
    /// RGB, each channel 0..1.
    color: [3]f32,
    /// Full world-space width/height of the rendered quad. Defaults to one world
    /// unit (a full grid cell on a unit-cell tilemap).
    size: f32 = 1,
    /// Silhouette to draw within the quad's footprint. Defaults to `.rect`, the
    /// pre-existing look — every package that declares no shape renders
    /// byte-identically to before this field existed.
    shape: gpu.Shape = .rect,
};

/// A navigation agent (ADR 0027): an entity the native `nav` steering system drives
/// toward a target grid cell each tick. `speed` is its movement rate in world units
/// per second along the path. The target cell itself is *not* held here — it lives in
/// the `nav_target_col`/`nav_target_row` named data components (ADR 0024), so a script
/// selects a new target with the existing `mana.set` (no new scripting API). An entity
/// needs `Transform` + `Velocity` + `NavAgent` (and the sim's scene tilemap) to be
/// steered: `nav` sets the agent's `Velocity` toward the next cell on the shortest
/// path and the `movement` system integrates it. Like `Velocity`/`Controller`, this is
/// movement *intent*, not authoritative state — its effect lands in the hashed
/// `Transform`, so it stays out of the determinism hash.
pub const NavAgent = struct {
    speed: f32 = 1,
};

/// The set of built-in components a deferred spawn attaches at once — an omitted
/// (null) field means the spawned entity lacks that component. This is the same
/// data-attachable set a scene `EntityDef` carries (ADR 0004 §6) and an entity
/// prototype declares (ADR 0016); the command buffer's `spawn`/`attach` carry a
/// `Bundle` so any built-in combination spawns in one deferred command. Grows
/// alongside the built-in components a scene/prototype may declare.
pub const Bundle = struct {
    transform: ?Transform = null,
    velocity: ?Velocity = null,
    health: ?Health = null,
    /// A collider to attach (ADR 0025), so a ZON-declared or `mana.spawn`-ed entity
    /// participates natively in the `collision` system and can reach
    /// `on_collision_begin` — the same shape `World.setCollider` already accepts.
    collider: ?Collider = null,
    /// Named scalar data components (ADR 0024) to register + attach at flush. A
    /// borrowed slice (the scene/prototype ZON owns it); empty ⇒ the spawned entity
    /// has no data components.
    data: []const NamedValue = &.{},
    /// A navigation agent (ADR 0027) to attach, so a ZON-declared or `mana.spawn`-ed
    /// entity is steered natively toward its target cell by the `nav` system — the same
    /// `NavAgent` `World.setNavAgent` accepts.
    nav_agent: ?NavAgent = null,
    /// A render appearance (ADR 0030) to attach — the color/size the renderer draws
    /// this entity with, in place of the palette-by-index fallback.
    appearance: ?Appearance = null,
};

/// Kinematic character-controller intent (ADR 0008 follow-on: move-and-slide).
/// `velocity` is the desired displacement rate this tick, world XY (2.5D — Z passes
/// through untouched, same plane the `Collider`/`collision` system operate on);
/// `skin` is the small clearance `controllerSystem` keeps from a surface after a
/// slide, so floating-point error does not immediately re-report contact next tick.
/// An entity needs `Transform` + a non-static `Collider` + `Controller` to be driven
/// by `controllerSystem`; it moves by recording a `set_transform` command (ADR 0007
/// §3), never by direct mutation.
pub const Controller = struct {
    velocity: Vec2 = .{ .x = 0, .y = 0 },
    skin: f32 = 0.01,
};
