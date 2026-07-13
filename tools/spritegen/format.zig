//! MSF1 — "mana sprite format", version 1 (ADR 0031 §2): the provisional, dependency-
//! free container `spritegen` emits and Lane B's engine will decode. It carries raw
//! straight-alpha RGBA8 frames plus a clip table, little-endian, no compression. It is
//! deliberately trivial (decode is a header read + slices) and **provisional** —
//! pending #109's interchange-codec decision, only the per-frame blob encoding would
//! change, behind the same versioned header.
//!
//! A sheet is a DERIVED artifact (never committed): the recipe `.zon` is the source of
//! truth (invariant #1). This module is the on-the-wire shape, exercised by a
//! round-trip test so encode/decode stay in lockstep.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Magic bytes at the start of every MSF1 file.
pub const magic = "MSF1";
/// Format version the header carries. A breaking change bumps this (e.g. "MSF2").
pub const version: u16 = 1;

/// A clip in decoded form: a name, a playback rate, and frame indices into `frames`.
pub const Clip = struct {
    name: []const u8,
    fps: u16,
    frames: []const u16,
};

/// A decoded (or to-be-encoded) sheet: square-free `width`×`height` frames plus clips.
/// On decode, all slices are owned by the caller (`free`); on encode, borrowed.
pub const Sheet = struct {
    width: u16,
    height: u16,
    /// One RGBA8 buffer per frame, each `width*height*4` bytes, row-major top-to-bottom.
    frames: []const []const u8,
    clips: []const Clip,
};

/// Errors `decode` can raise on a malformed or truncated buffer.
pub const DecodeError = error{ BadMagic, BadVersion, Truncated, SizeMismatch } || Allocator.Error;

/// Encode `sheet` to MSF1 bytes. Caller owns the result. Asserts each frame buffer is
/// exactly `width*height*4` bytes.
pub fn encode(gpa: Allocator, sheet: Sheet) Allocator.Error![]u8 {
    const frame_bytes: usize = @as(usize, sheet.width) * sheet.height * 4;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, magic);
    try appendInt(gpa, &out, u16, version);
    try appendInt(gpa, &out, u16, sheet.width);
    try appendInt(gpa, &out, u16, sheet.height);
    try appendInt(gpa, &out, u16, @intCast(sheet.frames.len));
    try appendInt(gpa, &out, u16, @intCast(sheet.clips.len));
    try appendInt(gpa, &out, u16, 0); // reserved

    for (sheet.frames) |f| {
        std.debug.assert(f.len == frame_bytes);
        try out.appendSlice(gpa, f);
    }
    for (sheet.clips) |clip| {
        try out.append(gpa, @intCast(clip.name.len));
        try out.appendSlice(gpa, clip.name);
        try appendInt(gpa, &out, u16, clip.fps);
        try appendInt(gpa, &out, u16, @intCast(clip.frames.len));
        for (clip.frames) |idx| try appendInt(gpa, &out, u16, idx);
    }
    return out.toOwnedSlice(gpa);
}

/// Decode MSF1 `bytes` into a `Sheet` whose slices are owned by the caller (free with
/// `free`). Rejects a bad magic/version or a truncated buffer.
pub fn decode(gpa: Allocator, bytes: []const u8) DecodeError!Sheet {
    var r: Reader = .{ .bytes = bytes };
    if (!std.mem.eql(u8, try r.take(4), magic)) return error.BadMagic;
    if (try r.int(u16) != version) return error.BadVersion;
    const width = try r.int(u16);
    const height = try r.int(u16);
    const frame_cnt = try r.int(u16);
    const clip_cnt = try r.int(u16);
    _ = try r.int(u16); // reserved

    const frame_bytes: usize = @as(usize, width) * height * 4;
    var frames = try gpa.alloc([]const u8, frame_cnt);
    var got: usize = 0;
    errdefer {
        for (frames[0..got]) |f| gpa.free(f);
        gpa.free(frames);
    }
    for (0..frame_cnt) |i| {
        frames[i] = try gpa.dupe(u8, try r.take(frame_bytes));
        got += 1;
    }

    var clips = try gpa.alloc(Clip, clip_cnt);
    var cgot: usize = 0;
    errdefer {
        for (clips[0..cgot]) |c| {
            gpa.free(c.name);
            gpa.free(c.frames);
        }
        gpa.free(clips);
    }
    for (0..clip_cnt) |i| {
        const name_len = try r.int(u8);
        const name = try gpa.dupe(u8, try r.take(name_len));
        errdefer gpa.free(name);
        const fps = try r.int(u16);
        const n = try r.int(u16);
        var idxs = try gpa.alloc(u16, n);
        errdefer gpa.free(idxs);
        for (0..n) |j| idxs[j] = try r.int(u16);
        clips[i] = .{ .name = name, .fps = fps, .frames = idxs };
        cgot += 1;
    }
    return .{ .width = width, .height = height, .frames = frames, .clips = clips };
}

/// Free a `Sheet` produced by `decode`.
pub fn free(gpa: Allocator, sheet: Sheet) void {
    for (sheet.frames) |f| gpa.free(f);
    gpa.free(sheet.frames);
    for (sheet.clips) |c| {
        gpa.free(c.name);
        gpa.free(c.frames);
    }
    gpa.free(sheet.clips);
}

/// Append a little-endian integer of type `T` to `out`.
fn appendInt(gpa: Allocator, out: *std.ArrayList(u8), comptime T: type, v: T) Allocator.Error!void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, v, .little);
    try out.appendSlice(gpa, &buf);
}

/// A cursor over a byte buffer that fails cleanly on truncation.
const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Reader, n: usize) DecodeError![]const u8 {
        if (self.pos + n > self.bytes.len) return error.Truncated;
        const s = self.bytes[self.pos..][0..n];
        self.pos += n;
        return s;
    }

    fn int(self: *Reader, comptime T: type) DecodeError!T {
        const s = try self.take(@sizeOf(T));
        return std.mem.readInt(T, s[0..@sizeOf(T)], .little);
    }
};

// --- Tests ------------------------------------------------------------------------

const testing = std.testing;

test "format: encode then decode round-trips a sheet" {
    const gpa = testing.allocator;
    const w: u16 = 3;
    const h: u16 = 2;
    var f0: [w * h * 4]u8 = undefined;
    var f1: [w * h * 4]u8 = undefined;
    for (&f0, 0..) |*b, i| b.* = @intCast(i & 0xff);
    for (&f1, 0..) |*b, i| b.* = @intCast((i * 3) & 0xff);
    const frames = [_][]const u8{ &f0, &f1 };
    const clips = [_]Clip{
        .{ .name = "chomp", .fps = 12, .frames = &.{ 0, 1, 0 } },
        .{ .name = "idle", .fps = 1, .frames = &.{0} },
    };
    const sheet: Sheet = .{ .width = w, .height = h, .frames = &frames, .clips = &clips };

    const bytes = try encode(gpa, sheet);
    defer gpa.free(bytes);
    try testing.expectEqualStrings(magic, bytes[0..4]);

    const back = try decode(gpa, bytes);
    defer free(gpa, back);
    try testing.expectEqual(w, back.width);
    try testing.expectEqual(h, back.height);
    try testing.expectEqual(@as(usize, 2), back.frames.len);
    try testing.expectEqualSlices(u8, &f0, back.frames[0]);
    try testing.expectEqualSlices(u8, &f1, back.frames[1]);
    try testing.expectEqualStrings("chomp", back.clips[0].name);
    try testing.expectEqual(@as(u16, 12), back.clips[0].fps);
    try testing.expectEqualSlices(u16, &.{ 0, 1, 0 }, back.clips[0].frames);
    try testing.expectEqualStrings("idle", back.clips[1].name);
}

test "format: decode rejects bad magic and truncation" {
    const gpa = testing.allocator;
    try testing.expectError(error.BadMagic, decode(gpa, "XXXX\x01\x00"));
    try testing.expectError(error.Truncated, decode(gpa, "MSF1"));
}
