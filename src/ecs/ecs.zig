//! ecs — minimal custom entity-component-system: entities are dense IDs,
//! components are plain data in contiguous SoA arrays, systems are free
//! functions iterating in cache order. Imports `core` only. No objects with
//! behavior, no virtual dispatch in loops. (ADR 0001: custom over zflecs.)

const std = @import("std");
const core = @import("core");

/// Placeholder marker verifying the module is wired into the build graph.
/// Replaced by the entity/component storage in a later task.
pub const ready = core.ready;

test "ecs module compiles and can import core" {
    try std.testing.expect(ready);
}
