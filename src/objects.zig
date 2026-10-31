// SPDX-License-Identifier: GPL-3.0-only
//! Git object identities and bounded pack-delta decoding.
const std = @import("std");

pub const max_object_bytes: usize = 16 * 1024 * 1024;
pub const Oid = [20]u8;
pub const Kind = enum { blob, tree, commit, tag };
pub const DecodeError = error{ InvalidOid, TruncatedDelta, InvalidDelta, ObjectTooLarge, Overflow };

pub fn parseOid(text: []const u8) DecodeError!Oid {
    if (text.len != 40) return error.InvalidOid;
    var oid: Oid = undefined;
    for (&oid, 0..) |*byte, i| {
        const hi = std.fmt.charToDigit(text[i * 2], 16) catch return error.InvalidOid;
        const lo = std.fmt.charToDigit(text[(i * 2) + 1], 16) catch return error.InvalidOid;
        byte.* = (hi << 4) | lo;
    }
    return oid;
}

pub fn formatOid(oid: Oid) [40]u8 {
    return std.fmt.bytesToHex(&oid, .lower);
}

pub fn hash(kind: Kind, data: []const u8) !Oid {
    if (data.len > max_object_bytes) return error.ObjectTooLarge;
    var buffer: [64]u8 = undefined;
    const header = try std.mem.print(&buffer, "{s} {d}\x00", .{ @tagName(kind), data.len });
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(header);
    sha.update(data);
    return sha.finalResult();
}

const Cursor = struct {
    bytes: []const u8,
    index: usize,

    fn byte(self: *Cursor) DecodeError!u8 {
        if (self.index >= self.bytes.len) return error.TruncatedDelta;
        const value = self.bytes[self.index];
        self.index += 1;
        return value;
    }

    fn size(self: *Cursor) DecodeError!usize {
        var value: u64 = 0;
        for (0..10) |i| {
            const b = try self.byte();
            if (i == 9 and (b & 0xfe) != 0) return error.Overflow;
            const shift = std.math.cast(u6, i * 7) orelse return error.Overflow;
            value |= @as(u64, b & 0x7f) << shift;
            if ((b & 0x80) == 0) {
                if (value > max_object_bytes) return error.ObjectTooLarge;
                return std.math.cast(usize, value) orelse error.Overflow;
            }
        }
        return error.Overflow;
    }
};

/// Returns owned bytes, freed by the caller with allocator.
pub fn applyDelta(allocator: std.mem.Allocator, base: []const u8, delta: []const u8) ![]u8 {
    if (base.len > max_object_bytes or delta.len > max_object_bytes) return error.ObjectTooLarge;
    var cursor: Cursor = .{ .bytes = delta, .index = 0 };
    if (try cursor.size() != base.len) return error.InvalidDelta;
    const target_size = try cursor.size();
    const result = try allocator.alloc(u8, target_size);
    errdefer allocator.free(result);
    var written: usize = 0;
    while (cursor.index < delta.len) {
        const opcode = try cursor.byte();
        if ((opcode & 0x80) != 0) {
            var offset: u32 = 0;
            var length: u32 = 0;
            for (0..4) |i| {
                const flag_shift = std.math.cast(u3, i) orelse return error.Overflow;
                if ((opcode & (@as(u8, 1) << flag_shift)) != 0) {
                    const shift = std.math.cast(u5, i * 8) orelse return error.Overflow;
                    offset |= @as(u32, try cursor.byte()) << shift;
                }
            }
            for (0..3) |i| {
                const flag_shift = std.math.cast(u3, i + 4) orelse return error.Overflow;
                if ((opcode & (@as(u8, 1) << flag_shift)) != 0) {
                    const shift = std.math.cast(u5, i * 8) orelse return error.Overflow;
                    length |= @as(u32, try cursor.byte()) << shift;
                }
            }
            if (length == 0) length = 0x10000;
            const start = std.math.cast(usize, offset) orelse return error.Overflow;
            const count = std.math.cast(usize, length) orelse return error.Overflow;
            if (start > base.len or count > base.len - start) return error.InvalidDelta;
            if (count > result.len - written) return error.InvalidDelta;
            @memcpy(result[written..][0..count], base[start..][0..count]);
            written += count;
        } else {
            if (opcode == 0) return error.InvalidDelta;
            const count: usize = opcode;
            if (count > delta.len - cursor.index or count > result.len - written) return error.InvalidDelta;
            @memcpy(result[written..][0..count], delta[cursor.index..][0..count]);
            written += count;
            cursor.index += count;
        }
    }
    if (written != target_size) return error.InvalidDelta;
    return result;
}

test "Git blob identity matches canonical SHA1" {
    const oid = try hash(.blob, "hello\n");
    try std.testing.expectEqualStrings("ce013625030ba8dba906f756967f9e9ca394464a", &formatOid(oid));
    try std.testing.expectEqual(oid, try parseOid(&formatOid(oid)));
    try std.testing.expectError(error.InvalidOid, parseOid("oops"));
    try std.testing.expectError(error.InvalidOid, parseOid("zz013625030ba8dba906f756967f9e9ca394464a"));
}

fn deltaCheck(allocator: std.mem.Allocator) !void {
    const value = try applyDelta(allocator, "hello", &.{ 5, 6, 0x90, 5, 1, '!' });
    defer allocator.free(value);
    try std.testing.expectEqualStrings("hello!", value);
}

test "delta copy and insertion have balanced ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, deltaCheck, .{});
}

test "delta rejects malformed lengths opcodes and truncated copies" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidDelta, applyDelta(allocator, "hello", &.{ 4, 1, 1, 'a' }));
    try std.testing.expectError(error.InvalidDelta, applyDelta(allocator, "hello", &.{ 5, 1, 0 }));
    try std.testing.expectError(error.InvalidDelta, applyDelta(allocator, "hello", &.{ 5, 1, 0x90, 6 }));
    try std.testing.expectError(error.TruncatedDelta, applyDelta(allocator, "hello", &.{ 5, 1, 0x91 }));
    try std.testing.expectError(error.InvalidDelta, applyDelta(allocator, "hello", &.{ 5, 1, 2, 'a' }));
    try std.testing.expectError(error.ObjectTooLarge, applyDelta(allocator, "", &.{ 0, 0xff, 0xff, 0xff, 0x7f }));
}

test "bounded malformed delta inputs never escape validation" {
    var bytes: [32]u8 = undefined;
    for (0..256) |seed| {
        for (&bytes, 0..) |*byte, i| byte.* = @truncate(seed + i);
        const result = applyDelta(std.testing.allocator, "base", &bytes) catch continue;
        std.testing.allocator.free(result);
    }
}
