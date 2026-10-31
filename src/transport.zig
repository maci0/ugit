// SPDX-License-Identifier: GPL-3.0-only
//! Git smart HTTP v0 transport with certificate verification through std.http.
const std = @import("std");
const config_file = @import("config.zig");
const Repo = @import("Repo.zig");
const objects = @import("objects.zig");
const pack = @import("pack.zig");

const max_advertisement_bytes: usize = 8 * 1024 * 1024;
const max_packets: usize = 1000000;
pub const Ref = struct { oid: objects.Oid, name: []const u8 };

const PacketReader = struct {
    bytes: []const u8,
    offset: usize,

    pub fn next(self: *PacketReader) !?[]const u8 {
        if (self.offset == self.bytes.len) return null;
        if (self.offset > self.bytes.len or self.bytes.len - self.offset < 4) return error.TruncatedPacket;
        const length = try std.fmt.parseInt(u16, self.bytes[self.offset..][0..4], 16);
        self.offset += 4;
        if (length == 0) return "";
        if (length < 4 or length - 4 > self.bytes.len - self.offset) return error.InvalidPacket;
        const result = self.bytes[self.offset..][0 .. length - 4];
        self.offset += length - 4;
        return result;
    }
};

fn packet(writer: *std.Io.Writer, bytes: []const u8) !void {
    if (bytes.len > 65516) return error.PacketTooLarge;
    const length = std.math.cast(u16, bytes.len + 4) orelse return error.PacketTooLarge;
    try writer.print("{x:0>4}", .{length});
    try writer.writeAll(bytes);
}

/// Caller frees the returned body.
fn request(allocator: std.mem.Allocator, io: std.Io, url: []const u8, payload: ?[]u8, limit: usize) ![]u8 {
    const uri = try std.Uri.parse(url);
    if (!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) return error.UnsupportedTransport;
    if (uri.user != null or uri.password != null) return error.UnsupportedCredentials;
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var req = try client.request(if (payload == null) .GET else .POST, uri, .{
        .keep_alive = false,
        .headers = .{ .content_type = .{ .override = "application/x-git-upload-pack-request" } },
    });
    defer req.deinit();
    if (payload) |body| try req.sendBodyComplete(body) else try req.sendBodiless();
    var header_buf: [8192]u8 = undefined;
    var response = try req.receiveHead(&header_buf);
    if (response.head.status != .ok) return error.HttpStatus;
    var read_buf: [16384]u8 = undefined;
    return response.reader(&read_buf).allocRemaining(allocator, .limited(limit));
}

/// Result names borrow bytes; caller frees the result slice.
fn advertisement(allocator: std.mem.Allocator, bytes: []const u8) ![]Ref {
    var reader: PacketReader = .{ .bytes = bytes, .offset = 0 };
    var refs: std.ArrayList(Ref) = .empty;
    errdefer refs.deinit(allocator);
    for (0..max_packets) |_| {
        var line = try reader.next() orelse return refs.toOwnedSlice(allocator);
        if (line.len == 0 or std.mem.startsWith(u8, line, "# service=")) continue;
        if (std.mem.findScalar(u8, line, 0)) |zero| line = line[0..zero];
        line = std.mem.trimEnd(u8, line, "\n");
        if (line.len < 42 or line[40] != ' ') return error.InvalidAdvertisement;
        const name = line[41..];
        if (std.mem.endsWith(u8, name, "^{}")) {
            if (!Repo.validRef(name[0 .. name.len - 3])) return error.InvalidAdvertisement;
            continue;
        }
        if (!std.mem.eql(u8, name, "HEAD") and !Repo.validRef(name)) return error.InvalidAdvertisement;
        if (!std.mem.eql(u8, name, "HEAD") and !std.mem.startsWith(u8, name, "refs/")) return error.InvalidAdvertisement;
        if (refs.items.len >= Repo.max_refs) return error.TooManyRefs;
        const oid = try objects.parseOid(line[0..40]);
        try refs.append(allocator, .{ .oid = oid, .name = name });
    }
    return error.TooManyPackets;
}

/// Fetches a complete pack, stores verified objects, and then updates remote refs.
pub fn fetch(repo: Repo, url: []const u8, remote: []const u8, prune: bool) !void {
    if (!Repo.validPath(remote) or std.mem.findScalar(u8, remote, '/') != null) return error.InvalidRemote;
    const base = std.mem.trimEnd(u8, url, "/");
    const advertise_url = try repo.allocator.print("{s}/info/refs?service=git-upload-pack", .{base});
    defer repo.allocator.free(advertise_url);
    const bytes = try request(repo.allocator, repo.io, advertise_url, null, max_advertisement_bytes);
    defer repo.allocator.free(bytes);
    const refs = try advertisement(repo.allocator, bytes);
    defer repo.allocator.free(refs);
    var wanted: std.ArrayList(objects.Oid) = .empty;
    defer wanted.deinit(repo.allocator);
    for (refs) |ref| {
        if (!std.mem.startsWith(u8, ref.name, "refs/heads/") and !std.mem.startsWith(u8, ref.name, "refs/tags/")) continue;
        const existing = repo.object(ref.oid) catch |err| switch (err) {
            error.UnknownObject => null,
            else => return err,
        };
        if (existing) |object| {
            repo.allocator.free(object.data);
            continue;
        }
        try wanted.append(repo.allocator, ref.oid);
    }
    if (wanted.items.len > 0) {
        const config = try repo.read("config");
        defer repo.allocator.free(config);
        const section = try repo.allocator.print("remote \"{s}\"", .{remote});
        defer repo.allocator.free(section);
        const filter = config_file.value(config, section, "partialclonefilter");
        const filtered = if (filter) |value| std.mem.eql(u8, value, "blob:none") else false;
        try download(repo, base, wanted.items, bytes, filtered, true);
    }
    for (refs) |ref| {
        const path = if (std.mem.startsWith(u8, ref.name, "refs/heads/"))
            try repo.allocator.print("refs/remotes/{s}/{s}", .{ remote, ref.name[11..] })
        else if (std.mem.startsWith(u8, ref.name, "refs/tags/"))
            try repo.allocator.dupe(u8, ref.name)
        else
            continue;
        defer repo.allocator.free(path);
        const object = try repo.object(ref.oid);
        repo.allocator.free(object.data);
        var line_buf: [41]u8 = undefined;
        try repo.write(path, try std.mem.print(&line_buf, "{s}\n", .{objects.formatOid(ref.oid)}));
    }
    if (prune) {
        const local_refs = try repo.refs();
        defer repo.freeRefs(local_refs);
        const prefix = try repo.allocator.print("refs/remotes/{s}/", .{remote});
        defer repo.allocator.free(prefix);
        for (local_refs) |local| {
            if (!std.mem.startsWith(u8, local.name, prefix) or std.mem.endsWith(u8, local.name, "/HEAD")) continue;
            var found = false;
            for (refs) |ref| if (std.mem.startsWith(u8, ref.name, "refs/heads/") and std.mem.eql(u8, local.name[prefix.len..], ref.name[11..])) {
                found = true;
                break;
            };
            if (!found) try repo.deleteRef(local.name);
        }
    }
}

fn importPack(repo: Repo, bytes: []const u8, promisor: bool) !void {
    if (bytes.len < 32 or !std.mem.eql(u8, bytes[0..4], "PACK")) return error.InvalidPack;
    const version = std.mem.readInt(u32, bytes[4..8], .big);
    if (version != 2 and version != 3) return error.InvalidPack;
    var digest: objects.Oid = undefined;
    std.crypto.hash.Sha1.hash(bytes[0 .. bytes.len - 20], &digest, .{});
    if (!std.mem.eql(u8, &digest, bytes[bytes.len - 20 ..])) return error.InvalidPackChecksum;
    const count = std.mem.readInt(u32, bytes[8..12], .big);
    if (count > pack.max_pack_objects) return error.TooManyObjects;
    const Record = struct { offset: usize, kind: u8, start: usize, length: usize, base_offset: ?usize, base_oid: ?objects.Oid, oid: ?objects.Oid };
    var records: std.ArrayList(Record) = .empty;
    defer records.deinit(repo.allocator);
    var offset_map: std.AutoHashMapUnmanaged(usize, usize) = .empty;
    defer offset_map.deinit(repo.allocator);
    var position: usize = 12;
    for (0..count) |_| {
        if (position >= bytes.len - 20) return error.TruncatedPack;
        const offset = position;
        var byte = bytes[position];
        position += 1;
        const kind: u8 = (byte >> 4) & 7;
        var size: u64 = byte & 15;
        var shift: usize = 4;
        while ((byte & 0x80) != 0) {
            if (position >= bytes.len - 20 or shift > 60) return error.InvalidPack;
            byte = bytes[position];
            position += 1;
            const amount = std.math.cast(u6, shift) orelse return error.Overflow;
            if (shift == 60 and (byte & 0x70) != 0) return error.Overflow;
            size |= @as(u64, byte & 0x7f) << amount;
            shift += 7;
        }
        if (size > objects.max_object_bytes) return error.ObjectTooLarge;
        var base_offset: ?usize = null;
        var base_oid: ?objects.Oid = null;
        if (kind == 6) {
            if (position >= bytes.len - 20) return error.TruncatedPack;
            byte = bytes[position];
            position += 1;
            var distance: usize = byte & 0x7f;
            for (0..10) |_| {
                if ((byte & 0x80) == 0) break;
                if (position >= bytes.len - 20) return error.TruncatedPack;
                byte = bytes[position];
                position += 1;
                distance = try std.math.add(usize, try std.math.mul(usize, try std.math.add(usize, distance, 1), 128), byte & 0x7f);
            }
            if ((byte & 0x80) != 0 or distance == 0 or distance > offset - 12) return error.InvalidPack;
            base_offset = offset - distance;
        } else if (kind == 7) {
            if (position > bytes.len - 20 or bytes.len - 20 - position < 20) return error.TruncatedPack;
            base_oid = bytes[position..][0..20].*;
            position += 20;
        }
        const start = position;
        var source = std.Io.Reader.fixed(bytes[position .. bytes.len - 20]);
        var inflater = std.compress.flate.Decompress.init(&source, .zlib, &.{});
        const inflated = try inflater.reader.allocRemaining(repo.allocator, .limited(objects.max_object_bytes));
        defer repo.allocator.free(inflated);
        if (inflated.len != size) return error.InvalidPack;
        position += source.seek;
        const oid: ?objects.Oid = switch (kind) {
            1 => try repo.storeObject(.commit, inflated),
            2 => try repo.storeObject(.tree, inflated),
            3 => try repo.storeObject(.blob, inflated),
            4 => try repo.storeObject(.tag, inflated),
            6, 7 => null,
            else => return error.InvalidPack,
        };
        try offset_map.put(repo.allocator, offset, records.items.len);
        try records.append(repo.allocator, .{ .offset = offset, .kind = kind, .start = start, .length = position - start, .base_offset = base_offset, .base_oid = base_oid, .oid = oid });
    }
    if (position != bytes.len - 20) return error.InvalidPack;
    for (0..64) |_| {
        var remaining: usize = 0;
        var progressed = false;
        for (records.items) |*record| {
            if (record.oid != null) continue;
            var base = record.base_oid;
            if (record.base_offset) |base_offset| {
                const base_index = offset_map.get(base_offset) orelse return error.MissingDeltaBase;
                if (base_index >= records.items.len) return error.InvalidPack;
                base = records.items[base_index].oid;
            }
            const base_id = base orelse {
                remaining += 1;
                continue;
            };
            const base_object = repo.object(base_id) catch |err| switch (err) {
                error.UnknownObject => {
                    remaining += 1;
                    continue;
                },
                else => return err,
            };
            defer repo.allocator.free(base_object.data);
            var source = std.Io.Reader.fixed(bytes[record.start..][0..record.length]);
            var inflater = std.compress.flate.Decompress.init(&source, .zlib, &.{});
            const delta = try inflater.reader.allocRemaining(repo.allocator, .limited(objects.max_object_bytes));
            defer repo.allocator.free(delta);
            const data = try objects.applyDelta(repo.allocator, base_object.data, delta);
            defer repo.allocator.free(data);
            record.oid = try repo.storeObject(base_object.kind, data);
            progressed = true;
        }
        if (remaining == 0) {
            const IndexEntry = struct { oid: objects.Oid, offset: u32, crc: u32 };
            const entries = try repo.allocator.alloc(IndexEntry, records.items.len);
            defer repo.allocator.free(entries);
            var fanout: [256]u32 = @splat(0);
            for (records.items, entries) |record, *entry| {
                const oid = record.oid orelse return error.MissingDeltaBase;
                const offset = std.math.cast(u32, record.offset) orelse return error.PackTooLarge;
                const end = try std.math.add(usize, record.start, record.length);
                if (end > bytes.len - 20 or record.offset > end) return error.InvalidPack;
                entry.* = .{ .oid = oid, .offset = offset, .crc = std.hash.Crc32.hash(bytes[record.offset..end]) };
                fanout[oid[0]] += 1;
            }
            std.mem.sort(IndexEntry, entries, {}, struct {
                fn less(_: void, a: IndexEntry, b: IndexEntry) bool {
                    return std.mem.order(u8, &a.oid, &b.oid) == .lt;
                }
            }.less);
            var index: std.Io.Writer.Allocating = .init(repo.allocator);
            defer index.deinit();
            try index.writer.writeAll("\xfftOc\x00\x00\x00\x02");
            var cumulative: u32 = 0;
            for (fanout) |value| {
                cumulative += value;
                try index.writer.writeInt(u32, cumulative, .big);
            }
            for (entries) |entry| try index.writer.writeAll(&entry.oid);
            for (entries) |entry| try index.writer.writeInt(u32, entry.crc, .big);
            for (entries) |entry| try index.writer.writeInt(u32, entry.offset, .big);
            try index.writer.writeAll(&digest);
            var index_digest: objects.Oid = undefined;
            std.crypto.hash.Sha1.hash(index.written(), &index_digest, .{});
            try index.writer.writeAll(&index_digest);
            const hex = objects.formatOid(digest);
            var name_buffer: [80]u8 = undefined;
            try repo.write(try std.mem.print(&name_buffer, "objects/pack/pack-{s}.pack", .{hex}), bytes);
            try repo.write(try std.mem.print(&name_buffer, "objects/pack/pack-{s}.idx", .{hex}), index.written());
            if (promisor) try repo.write(try std.mem.print(&name_buffer, "objects/pack/pack-{s}.promisor", .{hex}), "");
            for (entries) |entry| {
                const object_hex = objects.formatOid(entry.oid);
                const path = try std.mem.print(&name_buffer, "objects/{s}/{s}", .{ object_hex[0..2], object_hex[2..] });
                try repo.common.deleteFile(repo.io, path);
            }
            return;
        }
        if (!progressed) return error.MissingDeltaBase;
    }
    return error.DeltaChainTooDeep;
}

test "packet reader validates lengths and flush packets" {
    var reader: PacketReader = .{ .bytes = "0008abcd0000", .offset = 0 };
    try std.testing.expectEqualStrings("abcd", (try reader.next()) orelse return error.MissingPacket);
    try std.testing.expectEqualStrings("", (try reader.next()) orelse return error.MissingPacket);
    try std.testing.expect(try reader.next() == null);
    var broken: PacketReader = .{ .bytes = "0007x", .offset = 0 };
    try std.testing.expectError(error.InvalidPacket, broken.next());
}

fn capability(bytes: []const u8, name: []const u8) !bool {
    var reader: PacketReader = .{ .bytes = bytes, .offset = 0 };
    for (0..Repo.max_refs + 4) |_| {
        const line = try reader.next() orelse return false;
        const zero = std.mem.findScalar(u8, line, 0) orelse continue;
        var tokens = std.mem.tokenizeAny(u8, line[zero + 1 ..], " \n");
        while (tokens.next()) |token| if (std.mem.eql(u8, token, name)) return true;
        return false;
    }
    return error.TooManyRefs;
}

fn download(repo: Repo, base: []const u8, wanted: []const objects.Oid, advertised: []const u8, filter: bool, have_head: bool) !void {
    if (wanted.len == 0 or wanted.len > Repo.max_refs) return error.InvalidArguments;
    var body: std.Io.Writer.Allocating = .init(repo.allocator);
    defer body.deinit();
    const sideband = try capability(advertised, "side-band-64k");
    const ofs_delta = try capability(advertised, "ofs-delta");
    const filtered = filter and try capability(advertised, "filter");
    for (wanted, 0..) |oid, i| {
        var line_buf: [160]u8 = undefined;
        const first = i == 0;
        const line = try std.mem.print(&line_buf, "want {s}{s}{s}{s}\n", .{
            objects.formatOid(oid),
            if (first and sideband) " side-band-64k" else "",
            if (first and ofs_delta) " ofs-delta" else "",
            if (first and filtered) " filter" else "",
        });
        try packet(&body.writer, line);
    }
    if (filtered) try packet(&body.writer, "filter blob:none\n");
    try body.writer.writeAll("0000");
    if (have_head) {
        const head = repo.resolve("HEAD") catch |err| switch (err) {
            error.UnknownRef, error.FileNotFound => null,
            else => return err,
        };
        if (head) |oid| {
            var line: [64]u8 = undefined;
            try packet(&body.writer, try std.mem.print(&line, "have {s}\n", .{objects.formatOid(oid)}));
        }
    }
    try packet(&body.writer, "done\n");
    const upload_url = try repo.allocator.print("{s}/git-upload-pack", .{base});
    defer repo.allocator.free(upload_url);
    const response = try request(repo.allocator, repo.io, upload_url, body.written(), pack.max_pack_bytes + 1024 * 1024);
    defer repo.allocator.free(response);
    var wire: PacketReader = .{ .bytes = response, .offset = 0 };
    var pack_data: std.Io.Writer.Allocating = .init(repo.allocator);
    defer pack_data.deinit();
    for (0..max_packets) |_| {
        if (!sideband and std.mem.startsWith(u8, response[wire.offset..], "PACK")) {
            if (response.len - wire.offset > pack.max_pack_bytes) return error.PackTooLarge;
            try pack_data.writer.writeAll(response[wire.offset..]);
            break;
        }
        const line = try wire.next() orelse break;
        if (line.len == 0) continue;
        switch (line[0]) {
            1 => {
                if (line.len - 1 > pack.max_pack_bytes - pack_data.written().len) return error.PackTooLarge;
                try pack_data.writer.writeAll(line[1..]);
            },
            2 => {},
            3 => return error.RemoteFailure,
            else => if (!std.mem.startsWith(u8, line, "NAK") and !std.mem.startsWith(u8, line, "ACK")) return error.InvalidPacket,
        }
    }
    try importPack(repo, pack_data.written(), filtered);
}

/// Retrieves an omitted object from the configured partial-clone remote.
pub fn fetchMissing(repo: Repo, oid: objects.Oid) !void {
    if (!try repo.hasPromisorPacks()) return error.UnknownObject;
    const config = try repo.read("config");
    defer repo.allocator.free(config);
    const remote = config_file.value(config, "extensions", "partialClone") orelse return error.UnknownObject;
    const section = try repo.allocator.print("remote \"{s}\"", .{remote});
    defer repo.allocator.free(section);
    const url = config_file.value(config, section, "url") orelse return error.UnknownRemote;
    const base = std.mem.trimEnd(u8, url, "/");
    const advertise_url = try repo.allocator.print("{s}/info/refs?service=git-upload-pack", .{base});
    defer repo.allocator.free(advertise_url);
    const advertised = try request(repo.allocator, repo.io, advertise_url, null, max_advertisement_bytes);
    defer repo.allocator.free(advertised);
    try download(repo, base, &.{oid}, advertised, false, false);
}
