//! An embedded, dependency-free 5x7 bitmap font covering the full printable ASCII
//! range (0x20 space .. 0x7E tilde). This is the font/glyph-format decision ADR 0034 §6
//! deferred to issue #131: a fixed-width procedural bitmap glyph set baked into source,
//! in the same spirit as `tools/spritegen`'s procedural sprites — NO font-file
//! dependency (no FreeType / stb_truetype / TTF loader), so the default headless build
//! rasterizes text with zero external code (ADR 0036).
//!
//! Layout: each glyph is 7 rows of 5 columns. A row is a `u8` whose low 5 bits are the
//! columns, MSB-of-the-5 = leftmost column: bit `0b10000` is column 0 (left), bit
//! `0b00001` is column 4 (right). A set bit is an opaque (ink) texel; a clear bit is
//! transparent. The set is fixed-width: every glyph advances the same cell, so text
//! layout (`text.zig`) is pure integer arithmetic and trivially deterministic.

/// Glyph cell width in texels (columns).
pub const width: u16 = 5;
/// Glyph cell height in texels (rows).
pub const height: u16 = 7;
/// First ASCII codepoint in the table (space).
pub const first_char: u8 = 0x20;
/// Last ASCII codepoint in the table (tilde).
pub const last_char: u8 = 0x7E;
/// Number of glyphs baked in (`last_char - first_char + 1`).
pub const count: usize = last_char - first_char + 1;

/// True if `c` is a printable ASCII codepoint this font can render (space..tilde).
/// A codepoint outside the range has no glyph — the layout/atlas code treats it as an
/// unrenderable blank (see `glyph`).
pub fn has(c: u8) bool {
    return c >= first_char and c <= last_char;
}

/// The 7-row bitmap for codepoint `c`, or an all-zero (blank) glyph if `c` is outside
/// the printable ASCII range. Borrowed (points into `glyphs`); valid for the program's
/// lifetime. Row `r`'s low 5 bits are the columns (bit `0b10000` = leftmost).
pub fn glyph(c: u8) [7]u8 {
    if (!has(c)) return .{ 0, 0, 0, 0, 0, 0, 0 };
    return glyphs[c - first_char];
}

/// The baked 5x7 glyph table, indexed by `codepoint - first_char`. One row per line for
/// diffability; `0b10000` is the leftmost column of a row. Legible letterforms in the
/// 5x7 dot-matrix tradition (HD44780-style), authored here rather than imported.
const glyphs = [count][7]u8{
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 }, // 0x20 space
    .{ 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00000, 0b00100 }, // 0x21 !
    .{ 0b01010, 0b01010, 0b01010, 0b00000, 0b00000, 0b00000, 0b00000 }, // 0x22 "
    .{ 0b01010, 0b01010, 0b11111, 0b01010, 0b11111, 0b01010, 0b01010 }, // 0x23 #
    .{ 0b00100, 0b01111, 0b10100, 0b01110, 0b00101, 0b11110, 0b00100 }, // 0x24 $
    .{ 0b11000, 0b11001, 0b00010, 0b00100, 0b01000, 0b10011, 0b00011 }, // 0x25 %
    .{ 0b01100, 0b10010, 0b10100, 0b01000, 0b10101, 0b10010, 0b01101 }, // 0x26 &
    .{ 0b00100, 0b00100, 0b01000, 0b00000, 0b00000, 0b00000, 0b00000 }, // 0x27 '
    .{ 0b00010, 0b00100, 0b01000, 0b01000, 0b01000, 0b00100, 0b00010 }, // 0x28 (
    .{ 0b01000, 0b00100, 0b00010, 0b00010, 0b00010, 0b00100, 0b01000 }, // 0x29 )
    .{ 0b00000, 0b00100, 0b10101, 0b01110, 0b10101, 0b00100, 0b00000 }, // 0x2A *
    .{ 0b00000, 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0b00000 }, // 0x2B +
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00100, 0b00100, 0b01000 }, // 0x2C ,
    .{ 0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000 }, // 0x2D -
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b01100, 0b01100 }, // 0x2E .
    .{ 0b00001, 0b00010, 0b00100, 0b00100, 0b00100, 0b01000, 0b10000 }, // 0x2F /
    .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 }, // 0x30 0
    .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 }, // 0x31 1
    .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111 }, // 0x32 2
    .{ 0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110 }, // 0x33 3
    .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 }, // 0x34 4
    .{ 0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110 }, // 0x35 5
    .{ 0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 }, // 0x36 6
    .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 }, // 0x37 7
    .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 }, // 0x38 8
    .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100 }, // 0x39 9
    .{ 0b00000, 0b01100, 0b01100, 0b00000, 0b01100, 0b01100, 0b00000 }, // 0x3A :
    .{ 0b00000, 0b01100, 0b01100, 0b00000, 0b01100, 0b00100, 0b01000 }, // 0x3B ;
    .{ 0b00010, 0b00100, 0b01000, 0b10000, 0b01000, 0b00100, 0b00010 }, // 0x3C <
    .{ 0b00000, 0b00000, 0b11111, 0b00000, 0b11111, 0b00000, 0b00000 }, // 0x3D =
    .{ 0b01000, 0b00100, 0b00010, 0b00001, 0b00010, 0b00100, 0b01000 }, // 0x3E >
    .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b00000, 0b00100 }, // 0x3F ?
    .{ 0b01110, 0b10001, 0b10111, 0b10101, 0b10111, 0b10000, 0b01110 }, // 0x40 @
    .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 }, // 0x41 A
    .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 }, // 0x42 B
    .{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110 }, // 0x43 C
    .{ 0b11100, 0b10010, 0b10001, 0b10001, 0b10001, 0b10010, 0b11100 }, // 0x44 D
    .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 }, // 0x45 E
    .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 }, // 0x46 F
    .{ 0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01111 }, // 0x47 G
    .{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 }, // 0x48 H
    .{ 0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 }, // 0x49 I
    .{ 0b00111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100 }, // 0x4A J
    .{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 }, // 0x4B K
    .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 }, // 0x4C L
    .{ 0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001 }, // 0x4D M
    .{ 0b10001, 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001 }, // 0x4E N
    .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 }, // 0x4F O
    .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 }, // 0x50 P
    .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 }, // 0x51 Q
    .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 }, // 0x52 R
    .{ 0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110 }, // 0x53 S
    .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 }, // 0x54 T
    .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 }, // 0x55 U
    .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 }, // 0x56 V
    .{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b11011, 0b10001 }, // 0x57 W
    .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001 }, // 0x58 X
    .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100 }, // 0x59 Y
    .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 }, // 0x5A Z
    .{ 0b01110, 0b01000, 0b01000, 0b01000, 0b01000, 0b01000, 0b01110 }, // 0x5B [
    .{ 0b10000, 0b01000, 0b00100, 0b00100, 0b00100, 0b00010, 0b00001 }, // 0x5C backslash
    .{ 0b01110, 0b00010, 0b00010, 0b00010, 0b00010, 0b00010, 0b01110 }, // 0x5D ]
    .{ 0b00100, 0b01010, 0b10001, 0b00000, 0b00000, 0b00000, 0b00000 }, // 0x5E ^
    .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b11111 }, // 0x5F _
    .{ 0b01000, 0b00100, 0b00010, 0b00000, 0b00000, 0b00000, 0b00000 }, // 0x60 `
    .{ 0b00000, 0b00000, 0b01110, 0b00001, 0b01111, 0b10001, 0b01111 }, // 0x61 a
    .{ 0b10000, 0b10000, 0b10110, 0b11001, 0b10001, 0b10001, 0b11110 }, // 0x62 b
    .{ 0b00000, 0b00000, 0b01110, 0b10000, 0b10000, 0b10001, 0b01110 }, // 0x63 c
    .{ 0b00001, 0b00001, 0b01101, 0b10011, 0b10001, 0b10001, 0b01111 }, // 0x64 d
    .{ 0b00000, 0b00000, 0b01110, 0b10001, 0b11111, 0b10000, 0b01110 }, // 0x65 e
    .{ 0b00110, 0b01001, 0b01000, 0b11100, 0b01000, 0b01000, 0b01000 }, // 0x66 f
    .{ 0b00000, 0b01111, 0b10001, 0b10001, 0b01111, 0b00001, 0b01110 }, // 0x67 g
    .{ 0b10000, 0b10000, 0b10110, 0b11001, 0b10001, 0b10001, 0b10001 }, // 0x68 h
    .{ 0b00100, 0b00000, 0b01100, 0b00100, 0b00100, 0b00100, 0b01110 }, // 0x69 i
    .{ 0b00010, 0b00000, 0b00110, 0b00010, 0b00010, 0b10010, 0b01100 }, // 0x6A j
    .{ 0b10000, 0b10000, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010 }, // 0x6B k
    .{ 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 }, // 0x6C l
    .{ 0b00000, 0b00000, 0b11010, 0b10101, 0b10101, 0b10001, 0b10001 }, // 0x6D m
    .{ 0b00000, 0b00000, 0b10110, 0b11001, 0b10001, 0b10001, 0b10001 }, // 0x6E n
    .{ 0b00000, 0b00000, 0b01110, 0b10001, 0b10001, 0b10001, 0b01110 }, // 0x6F o
    .{ 0b00000, 0b00000, 0b11110, 0b10001, 0b11110, 0b10000, 0b10000 }, // 0x70 p
    .{ 0b00000, 0b00000, 0b01101, 0b10011, 0b01111, 0b00001, 0b00001 }, // 0x71 q
    .{ 0b00000, 0b00000, 0b10110, 0b11001, 0b10000, 0b10000, 0b10000 }, // 0x72 r
    .{ 0b00000, 0b00000, 0b01111, 0b10000, 0b01110, 0b00001, 0b11110 }, // 0x73 s
    .{ 0b01000, 0b01000, 0b11100, 0b01000, 0b01000, 0b01001, 0b00110 }, // 0x74 t
    .{ 0b00000, 0b00000, 0b10001, 0b10001, 0b10001, 0b10011, 0b01101 }, // 0x75 u
    .{ 0b00000, 0b00000, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 }, // 0x76 v
    .{ 0b00000, 0b00000, 0b10001, 0b10001, 0b10101, 0b10101, 0b01010 }, // 0x77 w
    .{ 0b00000, 0b00000, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001 }, // 0x78 x
    .{ 0b00000, 0b00000, 0b10001, 0b10001, 0b01111, 0b00001, 0b01110 }, // 0x79 y
    .{ 0b00000, 0b00000, 0b11111, 0b00010, 0b00100, 0b01000, 0b11111 }, // 0x7A z
    .{ 0b00010, 0b00100, 0b00100, 0b01000, 0b00100, 0b00100, 0b00010 }, // 0x7B {
    .{ 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 }, // 0x7C |
    .{ 0b01000, 0b00100, 0b00100, 0b00010, 0b00100, 0b00100, 0b01000 }, // 0x7D }
    .{ 0b00000, 0b00000, 0b01000, 0b10101, 0b00010, 0b00000, 0b00000 }, // 0x7E ~
};

const std = @import("std");
const testing = std.testing;

test "font5x7: covers the full printable ASCII range with the right cell size" {
    try testing.expectEqual(@as(usize, 95), count);
    try testing.expectEqual(@as(usize, 95), glyphs.len);
    try testing.expectEqual(@as(u16, 5), width);
    try testing.expectEqual(@as(u16, 7), height);
    try testing.expect(has(' '));
    try testing.expect(has('~'));
    try testing.expect(!has(0x1F)); // just below space
    try testing.expect(!has(0x7F)); // DEL, just past tilde
}

test "font5x7: space is blank; a letter has ink; an out-of-range code is blank" {
    // Space (0x20) is an all-zero cell — no ink texels.
    var space_bits: u32 = 0;
    for (glyph(' ')) |row| space_bits |= row;
    try testing.expectEqual(@as(u32, 0), space_bits);

    // A visible glyph must actually set some bits, or text would render invisibly.
    var a_bits: u32 = 0;
    for (glyph('A')) |row| a_bits |= row;
    try testing.expect(a_bits != 0);

    // A codepoint with no glyph (e.g. a control char) degrades to a blank cell.
    var ctrl_bits: u32 = 0;
    for (glyph(0x07)) |row| ctrl_bits |= row;
    try testing.expectEqual(@as(u32, 0), ctrl_bits);
}

test "font5x7: no glyph sets a bit outside the 5-column cell" {
    // Every row uses only the low 5 bits (0b11111); a stray high bit would mean a
    // mis-transcribed glyph that the atlas rasterizer would drop or misplace.
    for (glyphs) |g| {
        for (g) |row| try testing.expectEqual(@as(u8, 0), row & ~@as(u8, 0b11111));
    }
}
