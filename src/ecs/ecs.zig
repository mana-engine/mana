//! ecs — minimal custom entity-component-system primitives (ADR 0001, ADR 0004):
//! generational entity handles and sparse-set component storage. These are generic,
//! genre-neutral building blocks; the concrete `World` (which components exist and
//! the systems over them) is composed in `engine`. Imports `core` only.

const std = @import("std");
const core = @import("core");

pub const entity = @import("entity.zig");
pub const sparse_set = @import("sparse_set.zig");

pub const Entity = entity.Entity;
pub const EntityAllocator = entity.EntityAllocator;
pub const SparseSet = sparse_set.SparseSet;

/// Marker that the module is wired into the build graph.
pub const ready = core.ready;

test {
    std.testing.refAllDecls(@This());
    _ = entity;
    _ = sparse_set;
}
