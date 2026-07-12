//! File-watch port, polling adapter (ADR 0005). Host-stepped and single-threaded:
//! the caller registers paths and calls `poll` on its own cadence; `poll` re-stats
//! each file and reports whether any changed by mtime, size, or existence. Size is
//! checked alongside mtime to catch same-second edits coarse mtime resolution
//! misses. Native OS watchers are a future adapter behind this same shape.
//!
//! Paths are relative to a base directory captured at init — the runtime passes
//! `Io.Dir.cwd()`; tests pass a temp dir. This is `data`'s mechanism; the reload
//! *policy* (rebuild a World, last-good-wins) lives in `engine`/`runtime`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Watcher = struct {
    const Entry = struct {
        path: []u8,
        mtime_ns: i96,
        size: u64,
        exists: bool,
    };

    gpa: Allocator,
    base: Io.Dir,
    entries: std.ArrayList(Entry) = .empty,

    /// A watcher rooted at `base`. `gpa` owns the watch list; call `deinit`.
    pub fn init(gpa: Allocator, base: Io.Dir) Watcher {
        return .{ .gpa = gpa, .base = base };
    }

    pub fn deinit(self: *Watcher) void {
        for (self.entries.items) |e| self.gpa.free(e.path);
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    /// Start watching `path` (relative to the base dir). Records current state so
    /// the next `poll` reports no spurious change. A currently-missing file may be
    /// watched — its later creation registers as a change.
    pub fn add(self: *Watcher, io: Io, path: []const u8) Allocator.Error!void {
        const owned = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(owned);
        const s = self.snapshot(io, path);
        try self.entries.append(self.gpa, .{
            .path = owned,
            .mtime_ns = if (s) |v| v.mtime_ns else 0,
            .size = if (s) |v| v.size else 0,
            .exists = s != null,
        });
    }

    /// Re-stat every watched file; returns true if any changed since the last
    /// `poll`/`add`, updating stored state. Never errors — an unreadable file reads
    /// as "absent" and its reappearance is a change.
    pub fn poll(self: *Watcher, io: Io) bool {
        var changed = false;
        for (self.entries.items) |*e| {
            const s = self.snapshot(io, e.path);
            const exists = s != null;
            const mtime_ns: i96 = if (s) |v| v.mtime_ns else 0;
            const size: u64 = if (s) |v| v.size else 0;
            if (exists != e.exists or mtime_ns != e.mtime_ns or size != e.size) {
                e.* = .{ .path = e.path, .mtime_ns = mtime_ns, .size = size, .exists = exists };
                changed = true;
            }
        }
        return changed;
    }

    const Snapshot = struct { mtime_ns: i96, size: u64 };
    fn snapshot(self: *Watcher, io: Io, path: []const u8) ?Snapshot {
        const s = self.base.statFile(io, path, .{}) catch return null;
        return .{ .mtime_ns = s.mtime.nanoseconds, .size = s.size };
    }
};

const testing = std.testing;

test "watcher: reports create, modify, and delete" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;

    try tmp.dir.writeFile(io, .{ .sub_path = "s.zon", .data = "a" });

    var w = Watcher.init(gpa, tmp.dir);
    defer w.deinit();
    try w.add(io, "s.zon");

    try testing.expect(!w.poll(io)); // nothing changed since add

    try tmp.dir.writeFile(io, .{ .sub_path = "s.zon", .data = "abcd" }); // size 1 -> 4
    try testing.expect(w.poll(io));
    try testing.expect(!w.poll(io)); // stable again

    try tmp.dir.deleteFile(io, "s.zon"); // existence flips
    try testing.expect(w.poll(io));
    try testing.expect(!w.poll(io));
}

test "watcher: watching a missing file, then creating it, is a change" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    var w = Watcher.init(testing.allocator, tmp.dir);
    defer w.deinit();
    try w.add(io, "later.zon"); // absent at add time

    try testing.expect(!w.poll(io));
    try tmp.dir.writeFile(io, .{ .sub_path = "later.zon", .data = "x" });
    try testing.expect(w.poll(io));
}
