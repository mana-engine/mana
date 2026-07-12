//! Minimal PNG encoder for 8-bit RGBA images. Pure (pixels in, PNG bytes out),
//! dependency-free: it emits a zlib stream of **stored** (uncompressed) DEFLATE
//! blocks, so no compressor is needed. Used to turn the gpu backend's readback
//! pixels into a viewable, hashable artifact (ADR 0006). Not optimized for size.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Encode `rgba` (width*height*4 bytes, row-major, no padding) as a PNG. Caller
/// owns the returned bytes.
pub fn encode(gpa: Allocator, width: u32, height: u32, rgba: []const u8) Allocator.Error![]u8 {
    std.debug.assert(rgba.len == @as(usize, width) * height * 4);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, &.{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a });

    // IHDR: width, height, bit depth 8, colour type 6 (RGBA), no interlace.
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // colour type RGBA
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter
    ihdr[12] = 0; // interlace
    try writeChunk(gpa, &out, "IHDR", &ihdr);

    // Raw image data: each scanline prefixed with filter byte 0 (none).
    const stride = @as(usize, width) * 4;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    try raw.ensureTotalCapacity(gpa, height * (1 + stride));
    for (0..height) |y| {
        raw.appendAssumeCapacity(0); // filter: none
        raw.appendSliceAssumeCapacity(rgba[y * stride ..][0..stride]);
    }

    const idat = try zlibStored(gpa, raw.items);
    defer gpa.free(idat);
    try writeChunk(gpa, &out, "IDAT", idat);

    try writeChunk(gpa, &out, "IEND", &.{});
    return out.toOwnedSlice(gpa);
}

fn writeChunk(gpa: Allocator, out: *std.ArrayList(u8), tag: *const [4]u8, data: []const u8) Allocator.Error!void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len);
    try out.appendSlice(gpa, tag);
    try out.appendSlice(gpa, data);
    var crc = std.hash.crc.Crc32.init();
    crc.update(tag);
    crc.update(data);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
    try out.appendSlice(gpa, &crc_bytes);
}

/// Wrap `data` in a zlib stream using only stored (BTYPE=00) DEFLATE blocks.
fn zlibStored(gpa: Allocator, data: []const u8) Allocator.Error![]u8 {
    var z: std.ArrayList(u8) = .empty;
    errdefer z.deinit(gpa);
    try z.appendSlice(gpa, &.{ 0x78, 0x01 }); // zlib header (default compression)

    const max_block = 0xffff;
    var offset: usize = 0;
    while (true) {
        const remaining = data.len - offset;
        const block_len = @min(remaining, max_block);
        const final: u8 = if (offset + block_len >= data.len) 1 else 0;
        try z.append(gpa, final); // BFINAL bit, BTYPE=00
        var lens: [4]u8 = undefined;
        std.mem.writeInt(u16, lens[0..2], @intCast(block_len), .little); // LEN
        std.mem.writeInt(u16, lens[2..4], @intCast(~@as(u16, @intCast(block_len))), .little); // NLEN
        try z.appendSlice(gpa, &lens);
        try z.appendSlice(gpa, data[offset..][0..block_len]);
        offset += block_len;
        if (final == 1) break;
    }

    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, adler32(data), .big);
    try z.appendSlice(gpa, &adler);
    return z.toOwnedSlice(gpa);
}

fn adler32(data: []const u8) u32 {
    const mod = 65521;
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |byte| {
        a = (a + byte) % mod;
        b = (b + a) % mod;
    }
    return (b << 16) | a;
}

const testing = std.testing;

test "png: encodes a valid header for a 2x2 image" {
    const rgba = [_]u8{0xff} ** (2 * 2 * 4);
    const png = try encode(testing.allocator, 2, 2, &rgba);
    defer testing.allocator.free(png);

    try testing.expectEqualSlices(u8, &.{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a }, png[0..8]);
    // IHDR length (13) then tag, then width/height big-endian.
    try testing.expectEqual(@as(u32, 13), std.mem.readInt(u32, png[8..12], .big));
    try testing.expectEqualStrings("IHDR", png[12..16]);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, png[16..20], .big));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, png[20..24], .big));
}

test "png: IDAT is a well-formed stored-DEFLATE zlib stream" {
    const w = 3;
    const h = 2;
    var rgba: [w * h * 4]u8 = undefined;
    for (&rgba, 0..) |*b, i| b.* = @intCast(i & 0xff);
    const png = try encode(testing.allocator, w, h, &rgba);
    defer testing.allocator.free(png);

    // Walk chunks to find IDAT.
    var i: usize = 8;
    var idat: []const u8 = &.{};
    while (i + 8 <= png.len) {
        const clen = std.mem.readInt(u32, png[i..][0..4], .big);
        if (std.mem.eql(u8, png[i + 4 ..][0..4], "IDAT")) idat = png[i + 8 ..][0..clen];
        i += 12 + clen;
    }
    const raw_len = h * (1 + w * 4); // filter byte + pixels, per scanline

    try testing.expectEqualSlices(u8, &.{ 0x78, 0x01 }, idat[0..2]); // zlib header
    try testing.expectEqual(@as(u8, 1), idat[2]); // single final stored block
    try testing.expectEqual(@as(u16, raw_len), std.mem.readInt(u16, idat[3..5], .little)); // LEN
    try testing.expectEqual(@as(u16, ~@as(u16, raw_len)), std.mem.readInt(u16, idat[5..7], .little)); // NLEN
    try testing.expectEqual(@as(u8, 0), idat[7]); // filter byte of first scanline
    // header(2) + blockhdr(1) + len/nlen(4) + raw + adler(4)
    try testing.expectEqual(@as(usize, 2 + 1 + 4 + raw_len + 4), idat.len);
}
