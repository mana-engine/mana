//! The script↔engine host seam (ADR 0015): the abstract interface the live-Sim
//! `mana` accessors call through. `script` imports `core` only, so it cannot name
//! `World`/`CommandBuffer`/`ecs.Entity`; instead it declares this `core`-typed
//! vtable that `engine` fills for the duration of one event dispatch. Only
//! `core`/builtin types cross the seam — no Lua or engine type — so the module DAG
//! (`script → core`) and invariant #4 (Vulkan/engine internals never leak) hold.
//!
//! Compiled only under `-Denable-lua` (imported by `lua.zig`/`mana.zig`); no `zlua`
//! dependency itself, so this file is plain, dependency-free Zig over `core`.
//!
//! Wired so far (issue #5): the read surface — `is_valid`, `position`, `now` — and
//! the deferred-mutation surface — `set_velocity`, `despawn`, `spawn` (queued on the
//! engine's command buffer, applied at the next flush). The remaining accessors
//! (`set`, `get`, `random`) land as additive vtable entries in follow-up slices; the
//! *mechanism* here is fixed by ADR 0015 and does not churn.
//!
//! Mutations return nothing: they are fire-and-forget deferred commands (ADR 0003
//! §2). A stale handle is dropped at flush; allocation failure is recorded on the
//! engine-side ctx (not signalled through the seam) and aborts the tick — OOM is
//! never a content bug.

const core = @import("core");

/// A live view of the Sim a `mana` accessor may call into for the duration of one
/// event dispatch. `ctx` is an opaque pointer the engine owns and every vtable
/// function knows how to reinterpret; it is valid only while the engine has it
/// installed on a `State` (set around each dispatch, cleared after), so a `mana`
/// accessor invoked with no host present must degrade gracefully (nil/false) rather
/// than deref a stale `ctx`.
pub const Host = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// Function-pointer table over `core`-only types. `handle` is the ADR 0003 §4
    /// packed `u64` an opaque entity handle round-trips through Lua as. Grows
    /// additively as further #5 accessors land; the seam mechanism (ADR 0015) is
    /// fixed.
    pub const VTable = struct {
        /// True iff `handle` names a live entity (its generation matches the live
        /// slot). Stale/forged handles read `false` (ADR 0003 §2, §4).
        is_valid: *const fn (ctx: *anyopaque, handle: u64) bool,
        /// The entity's world position, or `null` if `handle` is stale or the
        /// entity has no `Transform` (ADR 0003 §2 `mana.position`).
        position: *const fn (ctx: *anyopaque, handle: u64) ?core.Vec3,
        /// Current sim time in seconds — tick-derived, never wall-clock, so it is
        /// deterministic and safe to branch on (ADR 0003 §2 `mana.now`).
        now: *const fn (ctx: *anyopaque) f64,
        /// Queue a velocity change on `handle` (world units/sec), applied at the
        /// next flush (deferred mutation, ADR 0003 §2). A stale handle is dropped at
        /// flush; allocation failure is recorded engine-side and aborts the tick.
        set_velocity: *const fn (ctx: *anyopaque, handle: u64, v: core.Vec3) void,
        /// Queue a despawn of `handle`, applied at the next flush (deferred). A stale
        /// handle is dropped at flush.
        despawn: *const fn (ctx: *anyopaque, handle: u64) void,
        /// Spawn the prototype named `name` at `pos` (ADR 0016). Reserves an entity
        /// immediately and returns its packed handle (valid at once, components
        /// attach at the next flush, ADR 0003 §2). An unknown prototype returns a
        /// packed invalid handle (a content bug the engine logs), never a crash.
        spawn: *const fn (ctx: *anyopaque, name: []const u8, pos: core.Vec3) u64,
    };

    /// Thin forwarders so callers read `host.position(h)` rather than threading
    /// `ctx` by hand. Each just dispatches through the vtable.
    pub fn isValid(self: Host, handle: u64) bool {
        return self.vtable.is_valid(self.ctx, handle);
    }
    pub fn position(self: Host, handle: u64) ?core.Vec3 {
        return self.vtable.position(self.ctx, handle);
    }
    pub fn now(self: Host) f64 {
        return self.vtable.now(self.ctx);
    }
    pub fn setVelocity(self: Host, handle: u64, v: core.Vec3) void {
        self.vtable.set_velocity(self.ctx, handle, v);
    }
    pub fn despawn(self: Host, handle: u64) void {
        self.vtable.despawn(self.ctx, handle);
    }
    pub fn spawn(self: Host, name: []const u8, pos: core.Vec3) u64 {
        return self.vtable.spawn(self.ctx, name, pos);
    }
};

const testing = @import("std").testing;

test "host: forwarders dispatch through the vtable to a fake ctx" {
    // A minimal fake host (no engine, no Lua) proves the seam is callable with only
    // `core` types — the same shape a test double or the real engine impl fills.
    const Fake = struct {
        valid: bool,
        pos: core.Vec3,
        t: f64,
        last_despawned: u64 = 0,
        last_vel: core.Vec3 = .{ .x = 0, .y = 0, .z = 0 },
        last_spawn_name: []const u8 = "",
        last_spawn_pos: core.Vec3 = .{ .x = 0, .y = 0, .z = 0 },

        fn isValid(ctx: *anyopaque, handle: u64) bool {
            _ = handle;
            return fromOpaque(ctx).valid;
        }
        fn position(ctx: *anyopaque, handle: u64) ?core.Vec3 {
            _ = handle;
            return fromOpaque(ctx).pos;
        }
        fn now(ctx: *anyopaque) f64 {
            return fromOpaque(ctx).t;
        }
        fn setVelocity(ctx: *anyopaque, handle: u64, v: core.Vec3) void {
            _ = handle;
            fromOpaque(ctx).last_vel = v;
        }
        fn despawn(ctx: *anyopaque, handle: u64) void {
            fromOpaque(ctx).last_despawned = handle;
        }
        fn spawn(ctx: *anyopaque, name: []const u8, pos: core.Vec3) u64 {
            const self = fromOpaque(ctx);
            self.last_spawn_name = name;
            self.last_spawn_pos = pos;
            return 77;
        }
        fn fromOpaque(ctx: *anyopaque) *@This() {
            return @ptrCast(@alignCast(ctx));
        }
        const vtable: Host.VTable = .{
            .is_valid = isValid,
            .position = position,
            .now = now,
            .set_velocity = setVelocity,
            .despawn = despawn,
            .spawn = spawn,
        };
    };

    var fake: Fake = .{ .valid = true, .pos = .{ .x = 1, .y = 2, .z = 3 }, .t = 0.5 };
    const host: Host = .{ .ctx = &fake, .vtable = &Fake.vtable };

    try testing.expect(host.isValid(0));
    try testing.expect(host.position(0).?.approxEql(.{ .x = 1, .y = 2, .z = 3 }, 1e-6));
    try testing.expectEqual(@as(f64, 0.5), host.now());

    host.setVelocity(0, .{ .x = 4, .y = 5, .z = 6 });
    try testing.expect(fake.last_vel.approxEql(.{ .x = 4, .y = 5, .z = 6 }, 1e-6));
    host.despawn(42);
    try testing.expectEqual(@as(u64, 42), fake.last_despawned);
    try testing.expectEqual(@as(u64, 77), host.spawn("segment", .{ .x = 7, .y = 8, .z = 9 }));
    try testing.expectEqualStrings("segment", fake.last_spawn_name);
    try testing.expect(fake.last_spawn_pos.approxEql(.{ .x = 7, .y = 8, .z = 9 }, 1e-6));
}
