//! Comptime ZON serializer + parser. `serialize` is our own reflection walk so we
//! own the on-disk format; `parse` builds on `std.zon.parse` (a full ZON parser is
//! not worth reimplementing). The round-trip guarantee `parse(serialize(x)) == x`
//! is the backbone of the files-as-source-of-truth architecture and is covered by
//! property tests below — it must never regress.

const std = @import("std");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

/// Serialize `value` to `w` as pretty-printed ZON (4-space indent, trailing
/// newline). Supports plain data: bools, ints, floats, enums, optionals, structs,
/// arrays, slices, and `[]const u8` strings. Fails only on writer errors;
/// unsupported types are rejected at compile time.
pub fn serialize(value: anytype, w: *Writer) Writer.Error!void {
    try writeValue(value, w, 0);
    try w.writeByte('\n');
}

fn writeIndent(w: *Writer, depth: usize) Writer.Error!void {
    for (0..depth) |_| try w.writeAll("    ");
}

fn writeValue(value: anytype, w: *Writer, depth: usize) Writer.Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => try w.writeAll(if (value) "true" else "false"),
        .int, .comptime_int => try w.print("{d}", .{value}),
        .float, .comptime_float => try w.print("{d}", .{value}),
        .@"enum", .enum_literal => {
            try w.writeByte('.');
            try w.writeAll(@tagName(value));
        },
        .optional => {
            if (value) |v| try writeValue(v, w, depth) else try w.writeAll("null");
        },
        .@"struct" => |s| {
            if (s.fields.len == 0) return w.writeAll(".{}");
            try w.writeAll(".{\n");
            inline for (s.fields) |f| {
                try writeIndent(w, depth + 1);
                if (!s.is_tuple) {
                    try w.writeByte('.');
                    try w.writeAll(f.name);
                    try w.writeAll(" = ");
                }
                try writeValue(@field(value, f.name), w, depth + 1);
                try w.writeAll(",\n");
            }
            try writeIndent(w, depth);
            try w.writeByte('}');
        },
        .array => try writeSequence(value, w, depth),
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8)
                try writeString(value, w)
            else
                try writeSequence(value, w, depth),
            .one => try writeValue(value.*, w, depth),
            else => @compileError("ZON serialize: unsupported pointer size on " ++ @typeName(T)),
        },
        else => @compileError("ZON serialize: unsupported type " ++ @typeName(T)),
    }
}

/// Write an array or non-u8 slice as a `.{ ... }` list, one element per line.
fn writeSequence(seq: anytype, w: *Writer, depth: usize) Writer.Error!void {
    if (seq.len == 0) return w.writeAll(".{}");
    try w.writeAll(".{\n");
    for (seq) |elem| {
        try writeIndent(w, depth + 1);
        try writeValue(elem, w, depth + 1);
        try w.writeAll(",\n");
    }
    try writeIndent(w, depth);
    try w.writeByte('}');
}

/// Write a byte slice as a quoted, escaped ZON string.
fn writeString(bytes: []const u8, w: *Writer) Writer.Error!void {
    try w.writeByte('"');
    for (bytes) |b| switch (b) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (b < 0x20)
            try w.print("\\x{x:0>2}", .{b})
        else
            try w.writeByte(b),
    };
    try w.writeByte('"');
}

/// Parse ZON `source` (must be NUL-terminated) into `T`. Allocations for slices and
/// strings in the result are owned by `gpa`; free with `free`. Unknown fields are
/// an error — use `parseLenient` to ignore them.
pub fn parse(comptime T: type, gpa: Allocator, source: [:0]const u8) error{ OutOfMemory, ParseZon }!T {
    // fromSliceAlloc handles both allocating (slices/strings) and plain types;
    // fromSlice would reject any type that owns a pointer at comptime.
    return std.zon.parse.fromSliceAlloc(T, gpa, source, null, .{});
}

/// Like `parse`, but silently ignores fields present in the source that `T` does
/// not declare (useful for forward-compatible manifests).
pub fn parseLenient(comptime T: type, gpa: Allocator, source: [:0]const u8) error{ OutOfMemory, ParseZon }!T {
    return std.zon.parse.fromSliceAlloc(T, gpa, source, null, .{ .ignore_unknown_fields = true });
}

/// Free a value produced by `parse`/`parseLenient`.
pub fn free(gpa: Allocator, value: anytype) void {
    std.zon.parse.free(gpa, value);
}

// --- Tests ------------------------------------------------------------------

const testing = std.testing;

/// Serialize `value`, parse it back into `T`, and assert deep equality.
fn expectRoundTrip(comptime T: type, value: T) !void {
    const gpa = testing.allocator;
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try serialize(value, &aw.writer);

    const z = try gpa.dupeZ(u8, aw.written());
    defer gpa.free(z);

    const parsed = try parse(T, gpa, z);
    defer free(gpa, parsed);
    try testing.expectEqualDeep(value, parsed);
}

test "zon round-trip: scalars (int, float, bool)" {
    // Floats are chosen exact-in-binary so formatting can never lose a bit.
    const S = struct { a: i32, b: u8, x: f32, y: f64, flag: bool };
    try expectRoundTrip(S, .{ .a = -7, .b = 200, .x = 1.5, .y = -0.25, .flag = true });
    try expectRoundTrip(S, .{ .a = 0, .b = 0, .x = 0, .y = 2.0, .flag = false });
}

test "zon round-trip: enums and optionals" {
    const Kind = enum { idle, walk, attack };
    const S = struct { kind: Kind, maybe: ?i32, none: ?u8 };
    try expectRoundTrip(S, .{ .kind = .walk, .maybe = 42, .none = null });
    try expectRoundTrip(S, .{ .kind = .idle, .maybe = null, .none = 5 });
}

test "zon round-trip: nested structs and arrays" {
    const P = struct { x: f32, y: f32 };
    const S = struct { pos: P, tri: [3]i32 };
    try expectRoundTrip(S, .{ .pos = .{ .x = -2.5, .y = 4.0 }, .tri = .{ 1, -2, 3 } });
}

test "zon round-trip: strings and slices" {
    const S = struct { name: []const u8, tags: []const []const u8, nums: []const u32 };
    try expectRoundTrip(S, .{
        .name = "player one",
        .tags = &.{ "hero", "spawnable" },
        .nums = &.{ 10, 20, 30 },
    });
}

test "zon round-trip: strings needing escapes" {
    const S = struct { s: []const u8 };
    try expectRoundTrip(S, .{ .s = "quote:\" backslash:\\ tab:\t newline:\n end" });
}

test "zon round-trip: empty containers" {
    const S = struct { items: []const u32, sub: struct {} };
    try expectRoundTrip(S, .{ .items = &.{}, .sub = .{} });
}

test "zon serialize: exact pretty-printed shape" {
    const S = struct { name: []const u8, hp: u32, pos: struct { x: f32, y: f32 } };
    const gpa = testing.allocator;
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try serialize(S{ .name = "crate", .hp = 10, .pos = .{ .x = 2, .y = 1 } }, &aw.writer);
    const expected =
        \\.{
        \\    .name = "crate",
        \\    .hp = 10,
        \\    .pos = .{
        \\        .x = 2,
        \\        .y = 1,
        \\    },
        \\}
        \\
    ;
    try testing.expectEqualStrings(expected, aw.written());
}
