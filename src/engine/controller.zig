//! The `controller` frame system (ADR 0008 follow-on): a registerable `engine.Sim`
//! system driving a kinematic character controller that moves an entity and slides
//! along static geometry instead of penetrating it. Each tick, for every entity with
//! `Transform` + a non-static `Collider` + `Controller`, it resolves the
//! controller's desired displacement (`Controller.velocity * dt`) against every
//! static collider: a tentative move that overlaps a static body is depenetrated
//! along the contact normal (`physics.contact`) and the remaining displacement is
//! projected onto the surface tangent (classic collide-and-slide), repeated up to
//! `max_iterations` times per tick to resolve a corner (two walls at once). The
//! resolved position is recorded through the command buffer
//! (`ctx.commands.setTransform`, ADR 0007 §3) — this system never mutates
//! `Transform` directly.
//!
//! Deterministic (sim-side): controller entities are visited in
//! controller-insertion order and static colliders in collider-insertion order, with
//! the deepest contact winning ties by that same order, so identical world state
//! yields an identical resolved position every run. This is a discrete,
//! overlap-based resolution, not a continuous sweep (ADR 0008 names sweep as a
//! still-unimplemented follow-on): a controller moving faster than its own diameter
//! in one tick can tunnel through thin geometry. That bound is acceptable until a
//! game needs high-speed movement against thin walls — sweep would be the fix then.

const std = @import("std");
const core = @import("core");
const physics = @import("physics");
const Context = @import("sim.zig").Context;
const SystemError = @import("sim.zig").SystemError;

const Vec2 = core.Vec2;

/// Depenetrate-and-slide passes per tick. Two walls meeting at a corner need at most
/// two resolving passes (one per wall); a couple of spare iterations absorb any
/// residual push-out from floating-point rounding without materially changing the
/// algorithm's cost (bounded, no allocation).
const max_iterations: u32 = 4;

/// Frame system: move every `Controller` entity by its desired velocity, sliding
/// along overlapping static colliders instead of penetrating them, and queue the
/// resolved position as a `set_transform` command. No-op for an entity missing
/// `Transform` or `Collider`, or whose own collider is static (nonsensical for a
/// controller — a controller moves, static geometry does not). Errors: only
/// `error.OutOfMemory`, propagated from queuing the command (ADR 0007 §3); the
/// system itself never reports `error.SystemFailed`.
pub fn controllerSystem(ctx: *Context) SystemError!void {
    const world = ctx.world;
    const ctl_indices = world.controllers.entities(); // []const u32, insertion order
    const ctl_data = world.controllers.slice();
    if (ctl_indices.len == 0) return;

    const static_indices = world.colliders.entities();
    const static_data = world.colliders.slice();

    for (ctl_indices, ctl_data) |ei, ctl| {
        const t = world.transforms.get(ei) orelse continue; // needs a transform to move
        const col = world.colliders.get(ei) orelse continue; // needs its own collider shape
        if (col.is_static) continue;

        var pos: Vec2 = .{ .x = t.pos.x, .y = t.pos.y };
        var remaining = ctl.velocity.scale(ctx.dt);

        var iter: u32 = 0;
        while (iter < max_iterations and (remaining.x != 0 or remaining.y != 0)) : (iter += 1) {
            const attempt = pos.add(remaining);
            const body = physics.place(col.shape, attempt);

            // Deepest contact wins deterministically: collider-insertion order,
            // strictly-greater depth replaces the current pick (ties keep the
            // earlier-inserted collider).
            var deepest: ?physics.Contact = null;
            for (static_indices, static_data) |sj, scol| {
                if (sj == ei or !scol.is_static) continue;
                if (!physics.Layers.canCollide(col.layers, scol.layers)) continue;
                const st = world.transforms.get(sj) orelse continue;
                const sbody = physics.place(scol.shape, .{ .x = st.pos.x, .y = st.pos.y });
                if (physics.contact(body, sbody)) |c| {
                    if (deepest == null or c.depth > deepest.?.depth) deepest = c;
                }
            }

            const c = deepest orelse {
                pos = attempt; // clear: commit the full tentative move, done this tick
                remaining = .{ .x = 0, .y = 0 };
                break;
            };

            // Depenetrate along the contact normal (plus a skin margin so the next
            // tick's overlap test does not immediately re-trigger), then slide: drop
            // the component of the remaining displacement pointing into the surface,
            // keep the tangential component for the next iteration.
            pos = attempt.add(c.normal.scale(c.depth + ctl.skin));
            const into = remaining.dot(c.normal);
            if (into < 0) remaining = remaining.sub(c.normal.scale(into));
        }

        if (pos.x != t.pos.x or pos.y != t.pos.y) {
            try ctx.commands.setTransform(ctx.gpa, world.entityAt(ei), .{
                .pos = .{ .x = pos.x, .y = pos.y, .z = t.pos.z },
            });
        }
    }
}

const testing = std.testing;
const Sim = @import("sim.zig").Sim;

fn circleCollider(radius: f32) @import("components.zig").Collider {
    return .{ .shape = .{ .circle = .{ .radius = radius } } };
}

/// A long, thin static wall as a capsule collider (ADR 0008: capsule is the
/// level-geometry shape). `dir` picks the spine axis; `half_len` is its half-length.
fn capsuleWall(dir: enum { horizontal, vertical }, half_len: f32, radius: f32) @import("components.zig").Collider {
    const seg: struct { a: Vec2, b: Vec2 } = switch (dir) {
        .horizontal => .{ .a = .{ .x = -half_len, .y = 0 }, .b = .{ .x = half_len, .y = 0 } },
        .vertical => .{ .a = .{ .x = 0, .y = -half_len }, .b = .{ .x = 0, .y = half_len } },
    };
    return .{ .shape = .{ .capsule = .{ .a = seg.a, .b = seg.b, .radius = radius } }, .is_static = true };
}

test "controller: pushed into a wall slides along it instead of penetrating" {
    var sim = Sim.init(testing.allocator, 0.1);
    defer sim.deinit();

    // A vertical wall at x=5 (capsule spine along Y, thickness 0.5). The controller
    // approaches diagonally: it should be blocked in x but keep moving in y.
    const wall = try sim.world.spawn();
    try sim.world.setTransform(wall, .{ .pos = .{ .x = 5, .y = 0, .z = 0 } });
    try sim.world.setCollider(wall, capsuleWall(.vertical, 50, 0.5));

    const mover = try sim.world.spawn();
    try sim.world.setTransform(mover, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try sim.world.setCollider(mover, circleCollider(0.4));
    try sim.world.setController(mover, .{ .velocity = .{ .x = 1, .y = 1 } });

    try sim.addSystem(controllerSystem);
    try sim.run(80); // plenty of ticks to press firmly into the wall

    const p = sim.world.getTransform(mover).?.pos;
    try testing.expect(p.x < 5.5 + 1e-3); // never penetrates past the wall surface
    try testing.expect(p.y > 5.0); // but kept sliding along it in y
}

test "controller: a head-on approach stops dead at the wall, no penetration" {
    var sim = Sim.init(testing.allocator, 0.1);
    defer sim.deinit();

    const wall = try sim.world.spawn();
    try sim.world.setTransform(wall, .{ .pos = .{ .x = 5, .y = 0, .z = 0 } });
    try sim.world.setCollider(wall, capsuleWall(.vertical, 50, 0.5));

    const mover = try sim.world.spawn();
    try sim.world.setTransform(mover, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try sim.world.setCollider(mover, circleCollider(0.4));
    try sim.world.setController(mover, .{ .velocity = .{ .x = 1, .y = 0 } }); // straight at the wall

    try sim.addSystem(controllerSystem);
    try sim.run(80);

    const p = sim.world.getTransform(mover).?.pos;
    try testing.expect(p.x < 5.5 + 1e-3); // clear of the wall surface
    try testing.expect(p.y == 0); // no lateral drift: a head-on hit has nothing to slide along
}

test "controller: moving parallel to a resting wall is unimpeded" {
    var sim = Sim.init(testing.allocator, 0.1);
    defer sim.deinit();

    const wall = try sim.world.spawn();
    try sim.world.setTransform(wall, .{ .pos = .{ .x = 5, .y = 0, .z = 0 } });
    try sim.world.setCollider(wall, capsuleWall(.vertical, 50, 0.5));

    // Start already resting against the wall (touching), moving purely tangential.
    const mover = try sim.world.spawn();
    try sim.world.setTransform(mover, .{ .pos = .{ .x = 4.5 - 1e-4, .y = 0, .z = 0 } });
    try sim.world.setCollider(mover, circleCollider(0.4));
    try sim.world.setController(mover, .{ .velocity = .{ .x = 0, .y = 2 } });

    try sim.addSystem(controllerSystem);
    try sim.run(10); // 10 * 0.1 * 2 = 2 units of y, if unimpeded

    const p = sim.world.getTransform(mover).?.pos;
    try testing.expect(p.y > 1.9); // travelled (near) the full tangential distance
    try testing.expect(p.x < 5.5 + 1e-3); // and never crossed the wall
}

test "controller: driven into a corner, it slides along both walls without tunnelling through" {
    var sim = Sim.init(testing.allocator, 0.05);
    defer sim.deinit();

    // An L-shaped corner: a horizontal wall at y=5 and a vertical wall at x=5.
    const wall_h = try sim.world.spawn();
    try sim.world.setTransform(wall_h, .{ .pos = .{ .x = 0, .y = 5, .z = 0 } });
    try sim.world.setCollider(wall_h, capsuleWall(.horizontal, 50, 0.5));

    const wall_v = try sim.world.spawn();
    try sim.world.setTransform(wall_v, .{ .pos = .{ .x = 5, .y = 0, .z = 0 } });
    try sim.world.setCollider(wall_v, capsuleWall(.vertical, 50, 0.5));

    const mover = try sim.world.spawn();
    try sim.world.setTransform(mover, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try sim.world.setCollider(mover, circleCollider(0.4));
    try sim.world.setController(mover, .{ .velocity = .{ .x = 1, .y = 1 } }); // straight at the corner

    try sim.addSystem(controllerSystem);
    try sim.run(400); // press firmly into the corner from every remaining tangent

    const p = sim.world.getTransform(mover).?.pos;
    try testing.expect(p.x < 5.5 + 1e-3); // bounded by the vertical wall
    try testing.expect(p.y < 5.5 + 1e-3); // bounded by the horizontal wall
}

test "controller: an entity without Controller is left untouched" {
    var sim = Sim.init(testing.allocator, 0.1);
    defer sim.deinit();

    const e = try sim.world.spawn();
    try sim.world.setTransform(e, .{ .pos = .{ .x = 1, .y = 2, .z = 3 } });
    try sim.world.setCollider(e, circleCollider(0.5));

    try sim.addSystem(controllerSystem);
    try sim.tick();

    try testing.expect(sim.world.getTransform(e).?.pos.approxEql(.{ .x = 1, .y = 2, .z = 3 }, 1e-6));
}

test "controller: moves are queued through the command buffer, not applied mid-tick" {
    // A regression guard for ADR 0007 §3: the position must still read as the *old*
    // value while `controllerSystem` runs (it only queues a `set_transform`); it
    // becomes visible only after the tick's flush.
    const Spy = struct {
        var saw_old_position: bool = false;
        fn after(ctx: *Context) SystemError!void {
            const idx = ctx.world.controllers.entities()[0];
            const t = ctx.world.transforms.get(idx).?;
            saw_old_position = t.pos.x == 0;
        }
    };
    Spy.saw_old_position = false;

    var sim = Sim.init(testing.allocator, 0.1);
    defer sim.deinit();
    const mover = try sim.world.spawn();
    try sim.world.setTransform(mover, .{ .pos = .{ .x = 0, .y = 0, .z = 0 } });
    try sim.world.setCollider(mover, circleCollider(0.4));
    try sim.world.setController(mover, .{ .velocity = .{ .x = 1, .y = 0 } });

    try sim.addSystem(controllerSystem);
    try sim.addSystem(Spy.after); // runs after controllerSystem, before the flush
    try sim.tick();

    try testing.expect(Spy.saw_old_position); // controllerSystem did not mutate directly
    try testing.expect(sim.world.getTransform(mover).?.pos.x > 0); // visible after flush
}
