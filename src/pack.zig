// SPDX-License-Identifier: GPL-3.0-only
//! Bounded Git pack v2/v3 reader, including OFS_DELTA and REF_DELTA.
const std = @import("std");
const objects = @import("objects.zig");

pub const max_pack_bytes: usize = 64 * 1024 * 1024;
pub const max_pack_objects: usize = 1000000;
const max_delta_depth: usize = 64;
pub const Object = struct { kind: objects.Kind, data: []u8 };

fn readBe(bytes: []const u8, offset: usize) !u32 {
    if (offset > bytes.len or bytes.len - offset < 4) return error.TruncatedPack;
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

pub fn indexOffset(index: []const u8, oid: objects.Oid) !?usize {
    if (index.len < 1072 or try readBe(index, 0) != 0xff744f63 or try readBe(index, 4) != 2) return error.InvalidIndex;
    var digest: objects.Oid = undefined;
    std.crypto.hash.Sha1.hash(index[0 .. index.len - 20], &digest, .{});
    if (!std.mem.eql(u8, &digest, index[index.len - 20 ..])) return error.InvalidIndexChecksum;
    const count = try readBe(index, 1028);
    if (count > max_pack_objects) return error.TooManyObjects;
    const names_start: usize = 1032;
    const name_bytes = try std.math.mul(usize, count, 20);
    const offset_start = try std.math.add(usize, names_start, try std.math.mul(usize, count, 24));
    const offsets_end = try std.math.add(usize, offset_start, try std.math.mul(usize, count, 4));
    if (offsets_end > index.len - 40 or name_bytes > index.len - names_start) return error.InvalidIndex;
    var low: usize = 0;
    var high: usize = count;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const position = names_start + mid * 20;
        switch (std.mem.order(u8, index[position..][0..20], &oid)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => {
                const value = try readBe(index, offset_start + mid * 4);
                if ((value & 0x80000000) == 0) return std.math.cast(usize, value) orelse error.Overflow;
                const large_index = value & 0x7fffffff;
                const large_position = try std.math.add(usize, offsets_end, try std.math.mul(usize, large_index, 8));
                if (large_position > index.len - 40 or index.len - 40 - large_position < 8) return error.InvalidIndex;
                const large = std.mem.readInt(u64, index[large_position..][0..8], .big);
                return std.math.cast(usize, large) orelse error.Overflow;
            },
        }
    }
    return null;
}

/// Returns caller-owned bytes or null when no pack contains oid.
pub fn find(allocator: std.mem.Allocator, io: std.Io, git: std.Io.Dir, oid: objects.Oid) !?Object {
    const dir = git.openDir(io, "objects/pack", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    var visited: usize = 0;
    while (try iterator.next(io)) |entry| {
        visited += 1;
        if (visited > 1024) return error.TooManyPacks;
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".idx")) continue;
        const index = try dir.readFileAlloc(io, entry.name, allocator, .limited(max_pack_bytes));
        defer allocator.free(index);
        const offset = try indexOffset(index, oid) orelse continue;
        var name_buf: [256]u8 = undefined;
        const name = try std.mem.print(&name_buf, "{s}.pack", .{entry.name[0 .. entry.name.len - 4]});
        const data = try dir.readFileAlloc(io, name, allocator, .limited(max_pack_bytes));
        defer allocator.free(data);
        return try decode(allocator, data, index, offset);
    }
    return null;
}

/// Returns caller-owned uncompressed data. Pack bytes and index remain borrowed.
fn decode(allocator: std.mem.Allocator, pack: []const u8, index: []const u8, initial: usize) !Object {
    if (pack.len < 32 or pack.len > max_pack_bytes or !std.mem.eql(u8, pack[0..4], "PACK")) return error.InvalidPack;
    var digest: objects.Oid = undefined;
    std.crypto.hash.Sha1.hash(pack[0 .. pack.len - 20], &digest, .{});
    if (!std.mem.eql(u8, &digest, pack[pack.len - 20 ..])) return error.InvalidPackChecksum;
    const version = try readBe(pack, 4);
    if (version != 2 and version != 3) return error.InvalidPack;
    if (try readBe(pack, 8) > max_pack_objects) return error.TooManyObjects;
    var chain: [max_delta_depth][]u8 = undefined;
    var depth: usize = 0;
    defer for (chain[0..depth]) |delta| allocator.free(delta);
    var offset = initial;
    var total: usize = 0;
    for (0..max_delta_depth) |_| {
        if (offset < 12 or offset >= pack.len - 20) return error.InvalidPack;
        const object_offset = offset;
        var byte = pack[offset];
        offset += 1;
        const kind = (byte >> 4) & 7;
        var size: u64 = byte & 15;
        var shift: usize = 4;
        while ((byte & 0x80) != 0) {
            if (offset >= pack.len - 20 or shift > 60) return error.InvalidPack;
            byte = pack[offset];
            offset += 1;
            if (shift == 60 and (byte & 0x70) != 0) return error.Overflow;
            const amount = std.math.cast(u6, shift) orelse return error.Overflow;
            size |= @as(u64, byte & 0x7f) << amount;
            shift += 7;
        }
        if (size > objects.max_object_bytes) return error.ObjectTooLarge;
        var base_offset: ?usize = null;
        if (kind == 6) {
            if (offset >= pack.len - 20) return error.TruncatedPack;
            byte = pack[offset];
            offset += 1;
            var distance: usize = byte & 0x7f;
            for (0..10) |_| {
                if ((byte & 0x80) == 0) break;
                if (offset >= pack.len - 20) return error.TruncatedPack;
                byte = pack[offset];
                offset += 1;
                distance = try std.math.add(usize, distance, 1);
                distance = try std.math.mul(usize, distance, 128);
                distance = try std.math.add(usize, distance, byte & 0x7f);
            }
            if ((byte & 0x80) != 0 or distance == 0 or distance > object_offset - 12) return error.InvalidPack;
            base_offset = object_offset - distance;
        } else if (kind == 7) {
            if (offset > pack.len - 20 or pack.len - 20 - offset < 20) return error.TruncatedPack;
            const base: objects.Oid = pack[offset..][0..20].*;
            offset += 20;
            base_offset = try indexOffset(index, base) orelse return error.MissingDeltaBase;
        }
        var source = std.Io.Reader.fixed(pack[offset .. pack.len - 20]);
        var inflater = std.compress.flate.Decompress.init(&source, .zlib, &.{});
        const Owned = struct { data: []u8 };
        var payload: Owned = .{ .data = try inflater.reader.allocRemaining(allocator, .limited(objects.max_object_bytes)) };
        errdefer allocator.free(payload.data);
        if (payload.data.len != size) return error.InvalidPack;
        total = try std.math.add(usize, total, payload.data.len);
        if (total > max_pack_bytes) return error.DeltaChainTooLarge;
        if (base_offset) |base| {
            if (depth >= chain.len) return error.DeltaChainTooDeep;
            chain[depth] = payload.data;
            depth += 1;
            offset = base;
            continue;
        }
        const object_kind: objects.Kind = switch (kind) {
            1 => .commit,
            2 => .tree,
            3 => .blob,
            4 => .tag,
            else => return error.InvalidPack,
        };
        var applied = depth;
        while (applied > 0) {
            applied -= 1;
            const next = try objects.applyDelta(allocator, payload.data, chain[applied]);
            allocator.free(payload.data);
            payload.data = next;
        }
        return .{ .kind = object_kind, .data = payload.data };
    }
    return error.DeltaChainTooDeep;
}

test "index and pack reject truncated input" {
    try std.testing.expectError(error.InvalidIndex, indexOffset("", @splat(0)));
    try std.testing.expectError(error.InvalidPack, decode(std.testing.allocator, "PACK", "", 12));
}
