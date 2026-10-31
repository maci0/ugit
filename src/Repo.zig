// SPDX-License-Identifier: GPL-3.0-only
//! Repository access. Owned objects are released by the caller.
const std = @import("std");
const objects = @import("objects.zig");
const Repo = @This();
const pack = @import("pack.zig");

allocator: std.mem.Allocator,
io: std.Io,
dir: std.Io.Dir,
git: std.Io.Dir,
common: std.Io.Dir,

pub const max_file_bytes: usize = 64 * 1024 * 1024;
pub const max_refs: usize = 100000;
pub const Object = struct {
    kind: objects.Kind,
    data: []u8,
};
pub const Ref = struct { name: []const u8, oid: objects.Oid };

pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Repo {
    const dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    errdefer dir.close(io);
    const git = dir.openDir(io, ".git", .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => blk: {
            const pointer = try dir.readFileAlloc(io, ".git", allocator, .limited(4096));
            defer allocator.free(pointer);
            if (!std.mem.startsWith(u8, pointer, "gitdir: ")) return error.InvalidGitDirectory;
            const target = std.mem.trimEnd(u8, pointer[8..], "\r\n");
            if (target.len == 0 or std.mem.findAny(u8, target, "\r\n\x00") != null) return error.InvalidGitDirectory;
            break :blk try dir.openDir(io, target, .{ .iterate = true });
        },
        else => return err,
    };
    errdefer git.close(io);
    const common_pointer = git.readFileAlloc(io, "commondir", allocator, .limited(4096)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (common_pointer) |bytes| allocator.free(bytes);
    const common_path = if (common_pointer) |bytes| std.mem.trimEnd(u8, bytes, "\r\n") else ".";
    if (common_path.len == 0 or std.mem.findAny(u8, common_path, "\r\n\x00") != null) return error.InvalidGitDirectory;
    const common = try git.openDir(io, common_path, .{ .iterate = true });
    return .{ .allocator = allocator, .io = io, .dir = dir, .git = git, .common = common };
}

pub fn close(self: Repo) void {
    self.common.close(self.io);
    self.git.close(self.io);
    self.dir.close(self.io);
}

/// Caller frees the returned data.
pub fn read(self: Repo, path: []const u8) ![]u8 {
    return self.metadataDir(path).readFileAlloc(self.io, path, self.allocator, .limited(max_file_bytes));
}

pub fn write(self: Repo, path: []const u8, data: []const u8) !void {
    if (data.len > max_file_bytes or !validPath(path)) return error.InvalidPath;
    if (std.mem.startsWith(u8, path, "refs/") and !validRef(path)) return error.InvalidRef;
    const parent = try self.gitParent(path);
    defer parent.dir.close(self.io);
    const lock = try self.allocator.print("{s}.lock", .{parent.name});
    defer self.allocator.free(lock);
    const file = try parent.dir.createFile(self.io, lock, .{ .exclusive = true });
    var renamed = false;
    defer {
        file.close(self.io);
        if (!renamed) parent.dir.deleteFile(self.io, lock) catch |err| std.log.err("remove lock: {s}", .{@errorName(err)});
    }
    try file.writeStreamingAll(self.io, data);
    try file.sync(self.io);
    try parent.dir.rename(lock, parent.dir, parent.name, self.io);
    renamed = true;
}

pub fn validPath(path: []const u8) bool {
    if (path.len == 0 or path.len > 4096 or path[0] == '/') return false;
    if (std.mem.findScalar(u8, path, 0) != null or std.mem.findScalar(u8, path, '\\') != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

/// Caller frees the returned reference name; detached HEAD returns null.
pub fn head(self: Repo) !?[]u8 {
    const data = try self.read("HEAD");
    defer self.allocator.free(data);
    if (!std.mem.startsWith(u8, data, "ref: ")) return null;
    const name = std.mem.trim(u8, data[5..], "\r\n");
    if (!validRef(name) or !std.mem.startsWith(u8, name, "refs/heads/")) return error.InvalidRef;
    return try self.allocator.dupe(u8, name);
}

pub fn resolve(self: Repo, input: []const u8) !objects.Oid {
    const name = if (std.mem.endsWith(u8, input, "^{commit}")) input[0 .. input.len - 9] else input;
    if (name.len == 40) return objects.parseOid(name);
    var buffer: [4096]u8 = undefined;
    const prefixes = [_][]const u8{ "", "refs/", "refs/tags/", "refs/heads/", "refs/remotes/" };
    for (prefixes) |prefix| {
        var path = try std.mem.print(&buffer, "{s}{s}", .{ prefix, name });
        if (!validPath(path)) continue;
        for (0..8) |_| {
            const data = self.read(path) catch |err| switch (err) {
                error.FileNotFound => break,
                else => return err,
            };
            defer self.allocator.free(data);
            if (std.mem.startsWith(u8, data, "ref: ")) {
                const target = std.mem.trim(u8, data[5..], "\r\n");
                if (!validPath(target) or target.len > buffer.len) return error.InvalidRef;
                @memmove(buffer[0..target.len], target);
                path = buffer[0..target.len];
                continue;
            }
            return objects.parseOid(std.mem.trim(u8, data, "\r\n"));
        }
        const ref_list = try self.refs();
        defer self.freeRefs(ref_list);
        for (ref_list) |ref| if (std.mem.eql(u8, ref.name, path)) return ref.oid;
    }
    if (name.len >= 4 and name.len < 40) {
        var hexadecimal = true;
        for (name) |byte| if (!std.ascii.isHex(byte)) {
            hexadecimal = false;
            break;
        };
        if (hexadecimal) {
            const oids = try self.allOids();
            defer self.allocator.free(oids);
            var found: ?objects.Oid = null;
            for (oids) |oid| {
                const hex = objects.formatOid(oid);
                if (std.ascii.eqlIgnoreCase(hex[0..name.len], name)) {
                    if (found != null) return error.AmbiguousObject;
                    found = oid;
                }
            }
            if (found) |oid| return oid;
        }
    }
    return error.UnknownRef;
}

pub fn freeRefs(self: Repo, refs_data: []Ref) void {
    for (refs_data) |ref| self.allocator.free(ref.name);
    self.allocator.free(refs_data);
}

/// Caller releases the result with freeRefs.
pub fn refs(self: Repo) ![]Ref {
    var list: std.ArrayList(Ref) = .empty;
    errdefer {
        for (list.items) |ref| self.allocator.free(ref.name);
        list.deinit(self.allocator);
    }
    if (self.read("packed-refs")) |data| {
        defer self.allocator.free(data);
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
            if (line.len < 42 or line[40] != ' ') return error.InvalidRef;
            if (!validPath(line[41..])) return error.InvalidRef;
            if (list.items.len >= max_refs) return error.TooManyRefs;
            const oid = try objects.parseOid(line[0..40]);
            const name = try self.allocator.dupe(u8, line[41..]);
            errdefer self.allocator.free(name);
            try list.append(self.allocator, .{ .name = name, .oid = oid });
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const refs_dir = self.common.openDir(self.io, "refs", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return list.toOwnedSlice(self.allocator),
        else => return err,
    };
    defer refs_dir.close(self.io);
    var walker = try refs_dir.walk(self.allocator);
    defer finishWalk(&walker, self.io);
    var visits: usize = 0;
    while (try walker.next(self.io)) |entry| {
        visits += 1;
        if (visits > max_refs) return error.TooManyRefs;
        if (entry.kind != .file) continue;
        const path = try self.allocator.print("refs/{s}", .{entry.path});
        errdefer self.allocator.free(path);
        const bytes = try self.read(path);
        defer self.allocator.free(bytes);
        if (std.mem.startsWith(u8, bytes, "ref: ")) {
            self.allocator.free(path);
            continue;
        }
        const oid = try objects.parseOid(std.mem.trim(u8, bytes, "\r\n"));
        var replaced = false;
        for (list.items) |*ref| {
            if (std.mem.eql(u8, ref.name, path)) {
                ref.oid = oid;
                replaced = true;
                break;
            }
        }
        if (replaced) self.allocator.free(path) else try list.append(self.allocator, .{ .name = path, .oid = oid });
    }
    return list.toOwnedSlice(self.allocator);
}

/// Caller frees object.data.
pub fn object(self: Repo, oid: objects.Oid) !Object {
    const hex = objects.formatOid(oid);
    var path_buf: [64]u8 = undefined;
    const path = try std.mem.print(&path_buf, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
    const compressed = self.read(path) catch |err| switch (err) {
        error.FileNotFound => {
            const packed_object = try pack.find(self.allocator, self.io, self.common, oid) orelse return error.UnknownObject;
            errdefer self.allocator.free(packed_object.data);
            const actual = try objects.hash(packed_object.kind, packed_object.data);
            if (!std.mem.eql(u8, &actual, &oid)) return error.InvalidObject;
            return .{ .kind = packed_object.kind, .data = packed_object.data };
        },
        else => return err,
    };
    defer self.allocator.free(compressed);
    var reader = std.Io.Reader.fixed(compressed);
    var inflater = std.compress.flate.Decompress.init(&reader, .zlib, &.{});
    const bytes = try inflater.reader.allocRemaining(self.allocator, .limited(objects.max_object_bytes + 64));
    defer self.allocator.free(bytes);
    const zero = std.mem.findScalar(u8, bytes, 0) orelse return error.InvalidObject;
    const space = std.mem.findScalar(u8, bytes[0..zero], ' ') orelse return error.InvalidObject;
    const size = try std.fmt.parseInt(usize, bytes[space + 1 .. zero], 10);
    const data = bytes[zero + 1 ..];
    if (size != data.len) return error.InvalidObject;
    const kind = std.meta.stringToEnum(objects.Kind, bytes[0..space]) orelse return error.InvalidObject;
    const actual = try objects.hash(kind, data);
    if (!std.mem.eql(u8, &actual, &oid)) return error.InvalidObject;
    return .{ .kind = kind, .data = try self.allocator.dupe(u8, data) };
}

test "repository paths reject traversal and ambiguous components" {
    for ([_][]const u8{ "../HEAD", "/HEAD", "refs//x", "refs/./x", "refs/../x", "refs\\x", "a\x00b" }) |path| try std.testing.expect(!validPath(path));
    try std.testing.expect(validPath("refs/heads/main"));
}

pub fn storeObject(self: Repo, kind: objects.Kind, data: []const u8) !objects.Oid {
    const oid = try objects.hash(kind, data);
    const hex = objects.formatOid(oid);
    var path_buffer: [64]u8 = undefined;
    const path = try std.mem.print(&path_buffer, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
    const raw_header = try self.allocator.print("{s} {d}\x00", .{ @tagName(kind), data.len });
    defer self.allocator.free(raw_header);
    const raw = try std.mem.concat(self.allocator, u8, &.{ raw_header, data });
    defer self.allocator.free(raw);
    var output: std.Io.Writer.Allocating = .init(self.allocator);
    defer output.deinit();
    try output.writer.writeAll(&.{ 0x78, 0x01 });
    var offset: usize = 0;
    var adler_a: u32 = 1;
    var adler_b: u32 = 0;
    while (offset < raw.len) {
        const length = @min(raw.len - offset, 65535);
        const block_length = std.math.cast(u16, length) orelse return error.Overflow;
        try output.writer.writeByte(if (length == raw.len - offset) 1 else 0);
        try output.writer.writeInt(u16, block_length, .little);
        try output.writer.writeInt(u16, ~block_length, .little);
        const block = raw[offset..][0..length];
        try output.writer.writeAll(block);
        for (block) |byte| {
            adler_a = (adler_a + byte) % 65521;
            adler_b = (adler_b + adler_a) % 65521;
        }
        offset += length;
    }
    try output.writer.writeInt(u32, (adler_b << 16) | adler_a, .big);
    try self.write(path, output.written());
    return oid;
}

pub fn validRef(name: []const u8) bool {
    if (!validPath(name) or !std.mem.startsWith(u8, name, "refs/")) return false;
    if (std.mem.findAny(u8, name, " ~^:?*[\\") != null or std.mem.find(u8, name, "..") != null or std.mem.find(u8, name, "@{") != null) return false;
    for (name) |byte| if (byte < 32 or byte == 127) return false;
    var components = std.mem.splitScalar(u8, name, '/');
    while (components.next()) |component| {
        if (component[0] == '.' or component[component.len - 1] == '.' or std.mem.endsWith(u8, component, ".lock")) return false;
    }
    return true;
}

pub fn deleteRef(self: Repo, path: []const u8) !void {
    if (!validRef(path)) return error.InvalidRef;
    const bytes = self.read("packed-refs") catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (bytes) |data| {
        defer self.allocator.free(data);
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        var skip_peeled = false;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (line[0] == '^' and skip_peeled) continue;
            skip_peeled = line.len > 41 and std.mem.eql(u8, line[41..], path);
            if (!skip_peeled) try output.writer.print("{s}\n", .{line});
        }
        try self.write("packed-refs", output.written());
    }
    self.common.deleteFile(self.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

/// Caller frees the returned list. OIDs are deduplicated across stores.
pub fn allOids(self: Repo) ![]objects.Oid {
    var seen: std.AutoHashMapUnmanaged(objects.Oid, void) = .empty;
    defer seen.deinit(self.allocator);
    const dir = try self.common.openDir(self.io, "objects", .{ .iterate = true });
    defer dir.close(self.io);
    var walker = try dir.walk(self.allocator);
    defer finishWalk(&walker, self.io);
    var visits: usize = 0;
    while (try walker.next(self.io)) |entry| {
        visits += 1;
        if (visits > pack.max_pack_objects + 1024) return error.TooManyObjects;
        if (entry.kind != .file) continue;
        if (entry.path.len == 41 and entry.path[2] == '/') {
            var hex: [40]u8 = undefined;
            @memcpy(hex[0..2], entry.path[0..2]);
            @memcpy(hex[2..], entry.path[3..]);
            const oid = objects.parseOid(&hex) catch continue;
            if (seen.count() >= pack.max_pack_objects) return error.TooManyObjects;
            try seen.put(self.allocator, oid, {});
        } else if (std.mem.startsWith(u8, entry.path, "pack/") and std.mem.endsWith(u8, entry.path, ".idx")) {
            const bytes = try dir.readFileAlloc(self.io, entry.path, self.allocator, .limited(max_file_bytes));
            defer self.allocator.free(bytes);
            _ = try pack.indexOffset(bytes, @splat(0));
            const count = std.mem.readInt(u32, bytes[1028..1032], .big);
            for (0..count) |i| {
                if (seen.count() >= pack.max_pack_objects) return error.TooManyObjects;
                const start = 1032 + i * 20;
                try seen.put(self.allocator, bytes[start..][0..20].*, {});
            }
        }
    }
    const result = try self.allocator.alloc(objects.Oid, seen.count());
    var iterator = seen.keyIterator();
    var i: usize = 0;
    while (iterator.next()) |oid| {
        result[i] = oid.*;
        i += 1;
    }
    return result;
}

fn gitParent(self: Repo, path: []const u8) !struct { dir: std.Io.Dir, name: []const u8 } {
    var dir = try self.metadataDir(path).openDir(self.io, ".", .{});
    errdefer dir.close(self.io);
    var parts = std.mem.splitScalar(u8, path, '/');
    var name = parts.next() orelse return error.InvalidPath;
    while (parts.next()) |next| {
        dir.createDir(self.io, name, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const child = try dir.openDir(self.io, name, .{ .follow_symlinks = false });
        dir.close(self.io);
        // misra-lint: allow use_after_close Assignment replaces the closed parent with a newly opened child handle.
        dir = child;
        name = next;
    }
    return .{ .dir = dir, .name = name };
}

/// Closes walker-owned handles even when traversal ends on an error.
pub fn finishWalk(walker: *std.Io.Dir.Walker, io: std.Io) void {
    while (walker.inner.stack.items.len > 0) walker.leave(io);
    walker.deinit();
}

fn metadataDir(self: Repo, path: []const u8) std.Io.Dir {
    if (std.mem.eql(u8, path, "HEAD") or std.mem.eql(u8, path, "index") or std.mem.eql(u8, path, "logs/HEAD")) return self.git;
    return self.common;
}

pub fn hasPromisorPacks(self: Repo) !bool {
    const dir = self.common.openDir(self.io, "objects/pack", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer dir.close(self.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(self.io)) |entry| {
        count += 1;
        if (count > 1024) return error.TooManyPacks;
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".promisor")) return true;
    }
    return false;
}
