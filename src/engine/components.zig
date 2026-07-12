//! Built-in engine components (ADR 0004 §3). These are genre-neutral spatial data
//! the engine's native systems operate on; game- or script-defined data components
//! are a deferred follow-on. Adding a built-in component here plus a column in
//! `World` and a system that uses it is the whole extension story.

const core = @import("core");
const physics = @import("physics");

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
