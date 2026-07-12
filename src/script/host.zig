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
//! This first slice (issue #5) carries the read-only surface — `is_valid`,
//! `position`, `now`. The deferred-mutation accessors (`set_velocity`, `despawn`,
//! `spawn`, `set`) and the `get`/`random` reads land as additive vtable entries in
//! follow-up slices; the *mechanism* here is fixed by ADR 0015 and does not churn.

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
};

const testing = @import("std").testing;

test "host: forwarders dispatch through the vtable to a fake ctx" {
    // A minimal fake host (no engine, no Lua) proves the seam is callable with only
    // `core` types — the same shape a test double or the real engine impl fills.
    const Fake = struct {
        valid: bool,
        pos: core.Vec3,
        t: f64,

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
        fn fromOpaque(ctx: *anyopaque) *@This() {
            return @ptrCast(@alignCast(ctx));
        }
        const vtable: Host.VTable = .{ .is_valid = isValid, .position = position, .now = now };
    };

    var fake: Fake = .{ .valid = true, .pos = .{ .x = 1, .y = 2, .z = 3 }, .t = 0.5 };
    const host: Host = .{ .ctx = &fake, .vtable = &Fake.vtable };

    try testing.expect(host.isValid(0));
    try testing.expect(host.position(0).?.approxEql(.{ .x = 1, .y = 2, .z = 3 }, 1e-6));
    try testing.expectEqual(@as(f64, 0.5), host.now());
}
