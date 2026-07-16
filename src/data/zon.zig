//! Comptime ZON serializer + parser. `serialize` is our own reflection walk so we
//! own the on-disk format; `parse` builds on `std.zon.parse` (a full ZON parser is
//! not worth reimplementing). The round-trip guarantee `parse(serialize(x)) == x`
//! is the backbone of the files-as-source-of-truth architecture and is covered by
//! property tests below — it must never regress.

const std = @import("std");
const Io = std.Io;
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

/// A ZON object whose field **names are runtime data**, not a Zig struct's comptime
/// fields — `serialize` writes it as an ordinary `.{ .<name> = <value>, … }` struct
/// literal, so the bytes are indistinguishable from any hand-written ZON object and
/// the matching parser reads them back unchanged.
///
/// This exists because `serialize` is a comptime reflection walk: a Zig type can only
/// describe an object whose field names are known at compile time. `input.zon`'s
/// `.actions` table (ADR 0040 §3) is the opposite — its field names *are* the
/// content-declared action names, unbounded and unknown to `src/**` (invariant #6) —
/// which is exactly why its *parser* (`engine/action_parse.zig`) had to walk the ZON
/// tree by hand rather than use `std.zon.parse` at the top level. `Object` is the
/// symmetric escape hatch on the *write* side, so persisting an override `input.zon`
/// (ADR 0041 §4) still goes through `saveFile` instead of hand-rolling ZON text.
///
/// `fields` is **borrowed** for the duration of the `serialize`/`saveFile` call; this
/// type owns nothing and frees nothing.
///
/// Each `name` is emitted **verbatim**, so it must be a valid bare ZON identifier —
/// the caller checks (`std.zig.isValidId`), because only the caller knows what to do
/// with a name that is not one. Names round-tripped out of a parsed ZON object always
/// are.
pub fn Object(comptime V: type) type {
    return struct {
        /// Marker `writeValue` dispatches on — its presence, not its value, is what
        /// distinguishes an `Object` from a plain struct that happens to have a
        /// `fields` member.
        pub const zon_object_value = V;

        pub const Field = struct { name: []const u8, value: V };

        fields: []const Field,
    };
}

fn writeIndent(w: *Writer, depth: usize) Writer.Error!void {
    for (0..depth) |_| try w.writeAll("    ");
}

/// Write an `Object(V)` as a `.{ .<name> = <value>, … }` literal — the runtime-named
/// counterpart of the comptime `.@"struct"` branch below, sharing its layout exactly.
fn writeObject(obj: anytype, w: *Writer, depth: usize) Writer.Error!void {
    if (obj.fields.len == 0) return w.writeAll(".{}");
    try w.writeAll(".{\n");
    for (obj.fields) |f| {
        try writeIndent(w, depth + 1);
        try w.writeByte('.');
        try w.writeAll(f.name);
        try w.writeAll(" = ");
        try writeValue(f.value, w, depth + 1);
        try w.writeAll(",\n");
    }
    try writeIndent(w, depth);
    try w.writeByte('}');
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
            // A runtime-named object (`Object(V)`) writes its own field names. The test
            // is exact — `T` must BE `Object(V)`, not merely carry the marker decl — so
            // an unrelated struct that happens to declare `zon_object_value` still
            // serializes as the plain struct it is.
            if (@hasDecl(T, "zon_object_value") and T == Object(T.zon_object_value)) {
                return writeObject(value, w, depth);
            }
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

/// Read `path` (relative to `dir`) and `parse` it as `T` — the file-level half of the
/// round trip `saveFile` writes (issue #135: a generic, genre-agnostic "load a ZON
/// table from disk" primitive; a game package supplies `T`'s shape, e.g. a settings
/// struct). The result owns heap allocations; free with `free`. Errors: whatever
/// `Io.Dir.readFileAllocOptions` reports (missing file, I/O failure) plus `parse`'s
/// `OutOfMemory`/`ParseZon`.
pub fn loadFile(comptime T: type, gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) !T {
    const src = try dir.readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0);
    defer gpa.free(src);
    return parse(T, gpa, src);
}

/// `serialize` `value` and write it to `path` (relative to `dir`), creating or
/// truncating the file — the generic "persist a ZON table to disk" primitive (issue
/// #135) `loadFile` reads back. Content (a game package) decides *what* gets saved and
/// *when*; this is genre-agnostic file I/O only, no policy. Errors: whatever
/// `Io.Dir.writeFile` reports (I/O failure) plus a writer error from `serialize` (never
/// hit in practice — the destination is an in-memory buffer).
pub fn saveFile(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8, value: anytype) !void {
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try serialize(value, &aw.writer);
    try dir.writeFile(io, .{ .sub_path = path, .data = aw.written() });
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

test "zon file persistence: saveFile writes ZON that loadFile parses back (round trip)" {
    const S = struct { volume: u8, name: []const u8 };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;

    const value: S = .{ .volume = 7, .name = "prefs" };
    try saveFile(gpa, io, tmp.dir, "settings.zon", value);

    const loaded = try loadFile(S, gpa, io, tmp.dir, "settings.zon");
    defer free(gpa, loaded);
    try testing.expectEqualDeep(value, loaded);
}

test "zon file persistence: a second saveFile overwrites the first, loadFile sees the latest" {
    const S = struct { n: i32 };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;

    try saveFile(gpa, io, tmp.dir, "s.zon", S{ .n = 1 });
    try saveFile(gpa, io, tmp.dir, "s.zon", S{ .n = 2 });

    const loaded = try loadFile(S, gpa, io, tmp.dir, "s.zon");
    try testing.expectEqual(@as(i32, 2), loaded.n);
}

test "zon serialize: an Object's runtime field names produce the same literal a comptime struct would" {
    // The proof `Object` is not a new dialect: an object built from *runtime* names
    // must be byte-identical to the equivalent hand-written Zig struct's output.
    const Inner = struct { hp: u32 };
    const gpa = testing.allocator;

    var dynamic: Writer.Allocating = .init(gpa);
    defer dynamic.deinit();
    const Obj = Object(Inner);
    // Names as `[]const u8` *values* — the shape a name read out of a file or a script
    // arrives in, and one no Zig struct's field list could have described.
    const fields = [_]Obj.Field{
        .{ .name = "crate", .value = .{ .hp = 10 } },
        .{ .name = "barrel", .value = .{ .hp = 3 } },
    };
    try serialize(Obj{ .fields = &fields }, &dynamic.writer);

    var static: Writer.Allocating = .init(gpa);
    defer static.deinit();
    try serialize(struct { crate: Inner, barrel: Inner }{
        .crate = .{ .hp = 10 },
        .barrel = .{ .hp = 3 },
    }, &static.writer);

    try testing.expectEqualStrings(static.written(), dynamic.written());
}

test "zon round-trip: an Object nested in a struct parses back through std.zon.parse" {
    // `Object` is write-side only (the read side of a runtime-named table is the
    // caller's own walk — e.g. `engine/action_parse.zig`), so the round trip is proven
    // against a *fixed*-shape `T` whose field names happen to match the ones written.
    const Inner = struct { hp: u32 };
    const gpa = testing.allocator;
    const Obj = Object(Inner);
    const fields = [_]Obj.Field{.{ .name = "crate", .value = .{ .hp = 10 } }};

    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try serialize(struct { items: Obj }{ .items = .{ .fields = &fields } }, &aw.writer);

    const z = try gpa.dupeZ(u8, aw.written());
    defer gpa.free(z);
    const parsed = try parse(struct { items: struct { crate: Inner } }, gpa, z);
    defer free(gpa, parsed);
    try testing.expectEqual(@as(u32, 10), parsed.items.crate.hp);
}

test "zon serialize: an unrelated struct carrying the marker decl still serializes as a plain struct" {
    // The `Object` test is by exact type, not by "has the decl" — so a caller's own
    // struct that happens to declare `zon_object_value` is not hijacked.
    const Impostor = struct {
        pub const zon_object_value = u8;
        fields: u8,
    };
    const gpa = testing.allocator;
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try serialize(Impostor{ .fields = 3 }, &aw.writer);
    try testing.expectEqualStrings(".{\n    .fields = 3,\n}\n", aw.written());
}

test "zon serialize: an empty Object writes the empty literal" {
    const gpa = testing.allocator;
    const Obj = Object(u8);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try serialize(Obj{ .fields = &.{} }, &aw.writer);
    try testing.expectEqualStrings(".{}\n", aw.written());
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
