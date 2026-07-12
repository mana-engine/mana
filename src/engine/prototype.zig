//! Entity prototypes (ADR 0016): named, `EntityDef`-shaped component templates a
//! package declares in ZON and `mana.spawn(name, x, y, z)` instantiates. The engine
//! holds a `Registry` (name → template) and resolves a spawn against it through the
//! host seam (ADR 0015); it knows the *format*, never a specific prototype
//! (invariant #6 — genre lives in content, not `src/`). A prototype is data, not
//! script (CLAUDE.md: prefer data over Lua).

const std = @import("std");
const core = @import("core");
const components = @import("components.zig");
const scene = @import("scene.zig");

const Allocator = std.mem.Allocator;

/// A prototype is exactly a scene entity definition (ADR 0004 §6): a `name` plus one
/// optional field per built-in component. Reused wholesale so there is one
/// entity-template shape across scenes and prototypes (ADR 0016).
pub const Prototype = scene.EntityDef;

/// The component set to attach when `proto` is spawned at `pos`: the template's
/// components with `Transform.pos` set to the spawn point — `mana.spawn`'s position
/// overrides the template's (ADR 0016). A prototype without a `transform` gets one
/// at the spawn point.
pub fn bundleAt(proto: Prototype, pos: core.Vec3) components.Bundle {
    var transform = proto.transform orelse components.Transform{ .pos = pos };
    transform.pos = pos; // spawn position wins over any template position
    return .{ .transform = transform, .velocity = proto.velocity, .health = proto.health };
}

/// Name → prototype lookup `mana.spawn` resolves against. A thin index over a slice
/// of prototypes owned elsewhere (the runner's parsed ZON, or a test's fixed array);
/// the registry itself allocates nothing. Linear scan: prototype counts are small
/// and lookup order does not affect determinism (spawns flow through the command
/// buffer regardless).
pub const Registry = struct {
    prototypes: []const Prototype = &.{},

    /// The prototype named `name`, or null if none matches (a content bug the caller
    /// reports; never a crash).
    pub fn lookup(self: Registry, name: []const u8) ?Prototype {
        for (self.prototypes) |p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }
};

const testing = std.testing;

test "prototype: bundleAt overrides the template position with the spawn point" {
    const proto: Prototype = .{
        .name = "crate",
        .transform = .{ .pos = .{ .x = 99, .y = 99, .z = 99 } }, // template pos ignored
        .health = .{ .current = 5, .max = 5 },
    };
    const bundle = bundleAt(proto, .{ .x = 1, .y = 2, .z = 3 });
    try testing.expect(bundle.transform.?.pos.approxEql(.{ .x = 1, .y = 2, .z = 3 }, 1e-6));
    try testing.expectEqual(@as(f32, 5), bundle.health.?.current); // other components carry through
    try testing.expect(bundle.velocity == null); // absent template component stays absent
}

test "prototype: bundleAt gives a transformless prototype a transform at the spawn point" {
    const proto: Prototype = .{ .name = "spark", .velocity = .{ .v = .{ .x = 1, .y = 0, .z = 0 } } };
    const bundle = bundleAt(proto, .{ .x = 4, .y = 5, .z = 6 });
    try testing.expect(bundle.transform.?.pos.approxEql(.{ .x = 4, .y = 5, .z = 6 }, 1e-6));
    try testing.expect(bundle.velocity.?.v.approxEql(.{ .x = 1, .y = 0, .z = 0 }, 1e-6));
}

test "prototype registry: lookup finds a named prototype and misses cleanly" {
    const protos = [_]Prototype{
        .{ .name = "head", .transform = .{ .pos = .{ .x = 0, .y = 0, .z = 0 } } },
        .{ .name = "food", .health = .{ .current = 1, .max = 1 } },
    };
    const reg: Registry = .{ .prototypes = &protos };
    try testing.expectEqualStrings("food", reg.lookup("food").?.name);
    try testing.expect(reg.lookup("missing") == null);
    try testing.expect((Registry{}).lookup("head") == null); // empty registry: always a miss
}
