//! MSF2 — "mana sprite format", version 2 (ADR 0031 §2, ADR 0033): the dependency-free
//! container `spritegen` emits (`encode`) and the engine decodes (`decode`). It carries
//! raw straight-alpha RGBA8 frames plus a clip table, little-endian, no compression. It
//! is deliberately trivial (decode is a header read + slices).
//!
//! MSF2 (ADR 0033) adds a per-clip **facing dimension**: alongside the non-directional
//! `frames` list (the single-facing fallback, unchanged), a clip may carry a phase list
//! per screen facing (up/down/left/right). A missing horizontal facing is X-flipped from
//! its opposite at render time (the "absence is the signal" mirror rule, ADR 0033 §2) —
//! the format stores only what is authored, no mirror boolean. The per-frame blob
//! encoding remains open (#109 could later swap it behind the versioned header).
//!
//! Lives in `data` (the file layer, beside `png`/`zon`) so it is the SINGLE definition
//! of the format: `tools/spritegen` imports `data.msf` to encode, the engine's sprite
//! loader imports the same `data.msf` to decode, and the round-trip test below pins the
//! two directions in lockstep — no external dependency on either side.
//!
//! A sheet is a DERIVED artifact (never committed): the recipe `.zon` is the source of
//! truth (invariant #1). This module is the on-the-wire shape.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Magic bytes at the start of every MSF2 file (bumped from `"MSF1"` for the facing
/// dimension, ADR 0033; MSF1 files no longer decode — sheets are regenerated artifacts).
pub const magic = "MSF2";
/// Format version the header carries. A breaking change bumps this.
pub const version: u16 = 2;

/// A screen-space travel facing a directional clip may carry a distinct phase list for
/// (ADR 0033). The engine classifies an entity's world-space heading into one of these
/// through the active projection; a non-directional clip carries none. The enum's
/// integer order (up, down, left, right) is the wire order of `Clip.facings` and its
/// facing-mask bits.
pub const Facing = enum(u2) { up, down, left, right };

/// A clip in decoded form (ADR 0031, ADR 0033): a name, a playback rate, the
/// non-directional `frames` phase list (the single-facing fallback), and an optional
/// phase list per screen facing. `facings[@intFromEnum(f)]` is null when facing `f` is
/// not authored — a missing horizontal facing is mirrored from its opposite at render
/// time (ADR 0033 §2), a missing vertical facing falls back to `frames`. Each phase list
/// holds frame indices into the sheet's `frames`.
pub const Clip = struct {
    name: []const u8,
    fps: u16,
    frames: []const u16,
    facings: [4]?[]const u16 = .{ null, null, null, null },
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

/// Encode `sheet` to MSF2 bytes. Caller owns the result. Asserts each frame buffer is
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
        try appendFrameList(gpa, &out, clip.frames);
        // Facing mask (bit i ⇒ facings[i] present, in enum order up/down/left/right),
        // then one phase list per present facing — MSF2's additive per-clip extension.
        var mask: u8 = 0;
        for (clip.facings, 0..) |f, i| {
            if (f != null) mask |= @as(u8, 1) << @intCast(i);
        }
        try out.append(gpa, mask);
        for (clip.facings) |f| {
            if (f) |list| try appendFrameList(gpa, &out, list);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Append a `u16` length-prefixed frame-index list to `out` (a clip's base or per-facing
/// phase list). Asserts the list fits a `u16` length.
fn appendFrameList(gpa: Allocator, out: *std.ArrayList(u8), list: []const u16) Allocator.Error!void {
    try appendInt(gpa, out, u16, @intCast(list.len));
    for (list) |idx| try appendInt(gpa, out, u16, idx);
}

/// Decode MSF2 `bytes` into a `Sheet` whose slices are owned by the caller (free with
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
        for (clips[0..cgot]) |c| freeClip(gpa, c);
        gpa.free(clips);
    }
    for (0..clip_cnt) |i| {
        const name_len = try r.int(u8);
        const name = try gpa.dupe(u8, try r.take(name_len));
        errdefer gpa.free(name);
        const fps = try r.int(u16);
        const base = try readFrameList(gpa, &r);
        errdefer gpa.free(base);
        // MSF2 per-clip facing mask + a phase list per present facing (enum order).
        var facings: [4]?[]const u16 = .{ null, null, null, null };
        errdefer for (facings) |f| {
            if (f) |list| gpa.free(list);
        };
        const mask = try r.int(u8);
        for (&facings, 0..) |*slot, bit| {
            if (mask & (@as(u8, 1) << @intCast(bit)) != 0) slot.* = try readFrameList(gpa, &r);
        }
        clips[i] = .{ .name = name, .fps = fps, .frames = base, .facings = facings };
        cgot += 1;
    }
    return .{ .width = width, .height = height, .frames = frames, .clips = clips };
}

/// Read a `u16` length-prefixed frame-index list from `r` (a clip's base or per-facing
/// phase list). Caller owns the returned slice.
fn readFrameList(gpa: Allocator, r: *Reader) DecodeError![]u16 {
    const n = try r.int(u16);
    var idxs = try gpa.alloc(u16, n);
    errdefer gpa.free(idxs);
    for (0..n) |j| idxs[j] = try r.int(u16);
    return idxs;
}

/// Free one decoded `Clip`'s owned slices (its name, base frame list, and any per-facing
/// lists). Shared by `decode`'s error path and `free`.
fn freeClip(gpa: Allocator, c: Clip) void {
    gpa.free(c.name);
    gpa.free(c.frames);
    for (c.facings) |f| {
        if (f) |list| gpa.free(list);
    }
}

/// Free a `Sheet` produced by `decode`.
pub fn free(gpa: Allocator, sheet: Sheet) void {
    for (sheet.frames) |f| gpa.free(f);
    gpa.free(sheet.frames);
    for (sheet.clips) |c| freeClip(gpa, c);
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
        // A directional clip (ADR 0033): base + up/down/right authored, left OMITTED so
        // it is inferred by mirroring right — the round-trip must preserve the absence.
        .{
            .name = "chomp",
            .fps = 12,
            .frames = &.{ 0, 1, 0 },
            .facings = .{
                &.{ 0, 1 }, // up
                &.{ 1, 0 }, // down
                null, // left — absent (mirror of right)
                &.{ 0, 1, 0 }, // right
            },
        },
        .{ .name = "idle", .fps = 1, .frames = &.{0} }, // non-directional, no facings
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
    // The facing dimension round-trips, absence included: left stays null (mirrored).
    try testing.expectEqualSlices(u16, &.{ 0, 1 }, back.clips[0].facings[@intFromEnum(Facing.up)].?);
    try testing.expectEqualSlices(u16, &.{ 1, 0 }, back.clips[0].facings[@intFromEnum(Facing.down)].?);
    try testing.expect(back.clips[0].facings[@intFromEnum(Facing.left)] == null);
    try testing.expectEqualSlices(u16, &.{ 0, 1, 0 }, back.clips[0].facings[@intFromEnum(Facing.right)].?);
    try testing.expectEqualStrings("idle", back.clips[1].name);
    // A non-directional clip carries no facings (single-facing fallback unchanged).
    for (back.clips[1].facings) |f| try testing.expect(f == null);
}

test "format: decode rejects bad magic and truncation" {
    const gpa = testing.allocator;
    try testing.expectError(error.BadMagic, decode(gpa, "XXXX\x02\x00"));
    try testing.expectError(error.BadMagic, decode(gpa, "MSF1\x01\x00")); // MSF1 no longer decodes
    try testing.expectError(error.Truncated, decode(gpa, "MSF2"));
}
