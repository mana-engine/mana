//! tracy — the profiler shim. A thin, comptime-gated wrapper over the Tracy client
//! (ztracy binding) that compiles to **nothing** unless `-Denable-tracy` is set, so
//! call sites (`tracy.zone(...)`, `tracy.frameMark()`, `tracy.plot(...)`, the
//! `TracingAllocator`) stay identical whether or not profiling is compiled in and a
//! default build pays zero overhead. This is the ONLY module that names a Tracy type
//! — Tracy is contained here exactly as Vulkan is contained to `gpu`; nothing above
//! imports the ztracy binding. Selected at comptime via `build_options.enable_tracy`;
//! `build.zig` adds the `ztracy` import and links the Tracy client into `core` only
//! under the flag (see ADR 0023). All emitted data is cosmetic and excluded from the
//! sim state hash (instrumentation only).

const std = @import("std");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// True when the Tracy client was compiled in (`-Denable-tracy`). A comptime
/// constant, so every guard below folds away in a default build.
pub const enabled: bool = build_options.enable_tracy;

/// The Tracy binding, present only under `-Denable-tracy`. The `@import("ztracy")`
/// lives in the comptime-true branch, so a default build (where `build.zig` never
/// adds the import) never resolves it — mirroring how `gpu.zig` guards the Vulkan
/// backend and `script.zig` guards the Lua backend.
const impl = if (enabled) @import("ztracy") else struct {};

/// A scoped profiling zone (RAII): open one with `zone`, close it with `end`
/// (typically `defer z.end();`). Zero-sized and a no-op when Tracy is off, so the
/// pattern reads the same in every build.
pub const Zone = struct {
    ctx: if (enabled) impl.ZoneCtx else void,

    /// Close the zone, recording its elapsed time in the profiler. A no-op without
    /// `-Denable-tracy`.
    pub inline fn end(self: Zone) void {
        if (enabled) self.ctx.End();
    }
};

/// Open a named profiling zone at the caller's source location. `src` is `@src()`;
/// `name` is a comptime static label shown in Tracy. Returns a `Zone` the caller
/// must `end` (use `defer`). Compiles to nothing without `-Denable-tracy`.
pub inline fn zone(comptime src: std.builtin.SourceLocation, comptime name: [:0]const u8) Zone {
    if (enabled) return .{ .ctx = impl.ZoneN(src, name) };
    return .{ .ctx = {} };
}

/// Mark the boundary of one rendered frame (call once per frame in the play loop).
/// A no-op without `-Denable-tracy`.
pub inline fn frameMark() void {
    if (enabled) impl.FrameMark();
}

/// Record a value on a named plot (a time series in Tracy — e.g. fps, entity
/// count). `name` is a comptime static label. A no-op without `-Denable-tracy`.
pub inline fn plot(comptime name: [:0]const u8, value: f64) void {
    if (enabled) impl.PlotF(name, value);
}

/// Emit a Tracy allocation event for `ptr` of `size` bytes. Internal to the
/// `TracingAllocator`; a no-op without `-Denable-tracy`.
inline fn emitAlloc(ptr: ?*const anyopaque, size: usize) void {
    if (enabled) impl.Alloc(ptr, size);
}

/// Emit a Tracy free event for `ptr`. Internal to the `TracingAllocator`; a no-op
/// without `-Denable-tracy`.
inline fn emitFree(ptr: ?*const anyopaque) void {
    if (enabled) impl.Free(ptr);
}

/// An allocator wrapper that reports every allocation and free to Tracy's memory
/// profiler while delegating the actual work to a `child` allocator. Under a default
/// build `allocator()` hands back the `child` unchanged — no vtable indirection, no
/// overhead — so wrapping is free when Tracy is off. `child` must outlive the
/// wrapper. The wrapper itself must have a stable address once `allocator()` is
/// called (the returned `Allocator` captures a pointer to it).
pub const TracingAllocator = struct {
    child: Allocator,

    /// Wrap `child`; its allocations are traced only under `-Denable-tracy`.
    pub fn init(child: Allocator) TracingAllocator {
        return .{ .child = child };
    }

    /// The `std.mem.Allocator` interface to use in place of `child`. Without
    /// `-Denable-tracy` this is `child` itself (identity, zero overhead); with the
    /// flag it is a tracing vtable over `self` (which must stay put afterwards).
    pub fn allocator(self: *TracingAllocator) Allocator {
        if (!enabled) return self.child;
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TracingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.rawAlloc(len, alignment, ret_addr);
        if (result) |ptr| emitAlloc(ptr, len);
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TracingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.child.rawResize(memory, alignment, new_len, ret_addr);
        if (ok) {
            // Same address, new size: report as a free of the old block + a fresh
            // alloc at the same pointer so Tracy's per-pointer accounting stays exact.
            emitFree(memory.ptr);
            emitAlloc(memory.ptr, new_len);
        }
        return ok;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TracingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.child.rawRemap(memory, alignment, new_len, ret_addr);
        if (result) |ptr| {
            // The allocation may have moved: free the old pointer, alloc the new one.
            emitFree(memory.ptr);
            emitAlloc(ptr, new_len);
        }
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *TracingAllocator = @ptrCast(@alignCast(ctx));
        emitFree(memory.ptr);
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

test "tracy shim compiles and no-ops without -Denable-tracy" {
    // In a default build every call folds to nothing; assert the surface is callable
    // and the tracing allocator is a faithful pass-through of its child.
    const z = zone(@src(), "test.zone");
    z.end();
    frameMark();
    plot("test.plot", 1.5);

    var tracing = TracingAllocator.init(std.testing.allocator);
    const a = tracing.allocator();
    const buf = try a.alloc(u8, 32);
    defer a.free(buf);
    try std.testing.expectEqual(@as(usize, 32), buf.len);
}
