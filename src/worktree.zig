// SPDX-License-Identifier: GPL-3.0-only
//! Index/tree decoding and checked worktree access.
const std = @import("std");
const Repo = @import("Repo.zig");
const graph = @import("graph.zig");
const objects = @import("objects.zig");

pub const max_entries: usize = 100000;
pub const Entry = struct { path: []const u8, oid: objects.Oid, mode: u32 };

pub fn free(repo: Repo, entries: []Entry) void {
    for (entries) |entry| repo.allocator.free(entry.path);
    repo.allocator.free(entries);
}

fn append(repo: Repo, entries: *std.ArrayList(Entry), path: []const u8, oid: objects.Oid, mode: u32) !void {
    if (entries.items.len >= max_entries) return error.TooManyFiles;
    if (!validPath(path)) return error.UnsafeTreePath;
    const copy = try repo.allocator.dupe(u8, path);
    errdefer repo.allocator.free(copy);
    try entries.append(repo.allocator, .{ .path = copy, .oid = oid, .mode = mode });
}

pub fn validPath(path: []const u8) bool {
    if (!Repo.validPath(path)) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (std.ascii.eqlIgnoreCase(part, ".git")) return false;
    return true;
}

/// Caller releases the returned entries with free.
pub fn tree(repo: Repo, commit_oid: objects.Oid) ![]Entry {
    const commit_object = try repo.object(try graph.peel(repo, commit_oid));
    defer repo.allocator.free(commit_object.data);
    const commit = try graph.parseCommit(commit_object.data);
    const Pending = struct { oid: objects.Oid, path: []const u8 };
    var pending: std.ArrayList(Pending) = .empty;
    defer {
        for (pending.items) |item| repo.allocator.free(item.path);
        pending.deinit(repo.allocator);
    }
    try pending.ensureUnusedCapacity(repo.allocator, 1);
    // misra-lint: allow try_before_release Ownership moves into pending without a fallible step; pending's defer frees every path.
    const root_path = try repo.allocator.dupe(u8, "");
    pending.appendAssumeCapacity(.{ .oid = commit.tree, .path = root_path });
    var result: std.ArrayList(Entry) = .empty;
    errdefer {
        for (result.items) |item| repo.allocator.free(item.path);
        result.deinit(repo.allocator);
    }
    var next: usize = 0;
    while (next < pending.items.len) : (next += 1) {
        const item = pending.items[next];
        const object = try repo.object(item.oid);
        defer repo.allocator.free(object.data);
        if (object.kind != .tree) return error.InvalidTree;
        var position: usize = 0;
        while (position < object.data.len) {
            const rest = object.data[position..];
            const space = std.mem.findScalar(u8, rest, ' ') orelse return error.InvalidTree;
            const zero = std.mem.findScalar(u8, rest, 0) orelse return error.InvalidTree;
            if (zero <= space or rest.len - zero - 1 < 20) return error.InvalidTree;
            const mode = try std.fmt.parseInt(u32, rest[0..space], 8);
            const name = rest[space + 1 .. zero];
            if (std.mem.findScalar(u8, name, '/') != null or !validPath(name)) return error.UnsafeTreePath;
            const path = try repo.allocator.print("{s}{s}{s}", .{ item.path, if (item.path.len == 0) "" else "/", name });
            defer repo.allocator.free(path);
            const oid: objects.Oid = rest[zero + 1 ..][0..20].*;
            if (mode == 0o40000) {
                if (pending.items.len >= max_entries) return error.TooManyFiles;
                const path_copy = try repo.allocator.dupe(u8, path);
                errdefer repo.allocator.free(path_copy);
                try pending.append(repo.allocator, .{ .oid = oid, .path = path_copy });
            } else if (mode == 0o100644 or mode == 0o100755 or mode == 0o120000) {
                try append(repo, &result, path, oid, mode);
            } else return error.UnsupportedTreeMode;
            position += zero + 21;
        }
    }
    std.mem.sort(Entry, result.items, {}, less);
    for (result.items, 0..) |entry, i| {
        if (i == 0) continue;
        const previous = result.items[i - 1].path;
        if (std.mem.eql(u8, previous, entry.path)) return error.InvalidTree;
        if (std.mem.startsWith(u8, entry.path, previous) and entry.path.len > previous.len and entry.path[previous.len] == '/') return error.InvalidTree;
    }
    return result.toOwnedSlice(repo.allocator);
}

fn less(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

/// Caller releases the returned entries with free. Accepts Git index versions 2/3.
pub fn index(repo: Repo) ![]Entry {
    const bytes = repo.read("index") catch |err| switch (err) {
        error.FileNotFound => return repo.allocator.alloc(Entry, 0),
        else => return err,
    };
    defer repo.allocator.free(bytes);
    if (bytes.len < 32 or !std.mem.eql(u8, bytes[0..4], "DIRC")) return error.InvalidIndex;
    const version = std.mem.readInt(u32, bytes[4..8], .big);
    if (version != 2 and version != 3) return error.UnsupportedIndexVersion;
    var digest: objects.Oid = undefined;
    std.crypto.hash.Sha1.hash(bytes[0 .. bytes.len - 20], &digest, .{});
    if (!std.mem.eql(u8, &digest, bytes[bytes.len - 20 ..])) return error.InvalidIndex;
    const count = std.mem.readInt(u32, bytes[8..12], .big);
    if (count > max_entries) return error.TooManyFiles;
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| repo.allocator.free(entry.path);
        entries.deinit(repo.allocator);
    }
    var offset: usize = 12;
    for (0..count) |_| {
        if (offset > bytes.len - 20 or bytes.len - 20 - offset < 63) return error.InvalidIndex;
        const header = bytes[offset..][0..62];
        const flags = std.mem.readInt(u16, header[60..62], .big);
        if ((flags & 0x3000) != 0) return error.UnmergedIndex;
        const extra: usize = if ((flags & 0x4000) != 0) 2 else 0;
        const name_start = offset + 62 + extra;
        if (name_start >= bytes.len - 20) return error.InvalidIndex;
        const length = std.mem.findScalar(u8, bytes[name_start .. bytes.len - 20], 0) orelse return error.InvalidIndex;
        if (length > 4096) return error.UnsafeTreePath;
        try append(repo, &entries, bytes[name_start..][0..length], header[40..60].*, std.mem.readInt(u32, header[24..28], .big));
        const entry_size = 62 + extra + length + 1;
        offset += (entry_size + 7) & ~@as(usize, 7);
    }
    if (offset > bytes.len - 20) return error.InvalidIndex;
    return entries.toOwnedSlice(repo.allocator);
}

pub const Parent = struct {
    dir: std.Io.Dir,
    name: []const u8,
};

/// Opens each parent separately without following symlinks. Caller closes dir.
pub fn parent(repo: Repo, path: []const u8, create: bool) !Parent {
    if (!validPath(path)) return error.UnsafeTreePath;
    var dir = try repo.dir.openDir(repo.io, ".", .{});
    errdefer dir.close(repo.io);
    var parts = std.mem.splitScalar(u8, path, '/');
    var name = parts.next() orelse return error.UnsafeTreePath;
    while (parts.next()) |next| {
        if (create) dir.createDir(repo.io, name, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const child = try dir.openDir(repo.io, name, .{ .follow_symlinks = false });
        dir.close(repo.io);
        // misra-lint: allow use_after_close This assigns the newly opened child handle; it does not use the closed parent.
        dir = child;
        name = next;
    }
    return .{ .dir = dir, .name = name };
}

pub fn worktreeOid(repo: Repo, entry: Entry) !?objects.Oid {
    const p = parent(repo, entry.path, false) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.SymLinkLoop => return null,
        else => return err,
    };
    defer p.dir.close(repo.io);
    const stat = p.dir.statFile(repo.io, p.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (stat.kind == .sym_link) {
        var buf: [4096]u8 = undefined;
        const length = try p.dir.readLink(repo.io, p.name, &buf);
        return try objects.hash(.blob, buf[0..length]);
    }
    if (stat.kind != .file) return null;
    const data = try p.dir.readFileAlloc(repo.io, p.name, repo.allocator, .limited(objects.max_object_bytes));
    defer repo.allocator.free(data);
    return try objects.hash(.blob, data);
}

pub fn writeIndex(repo: Repo, entries: []const Entry, lock: std.Io.File) !void {
    var bytes: std.Io.Writer.Allocating = .init(repo.allocator);
    defer bytes.deinit();
    try bytes.writer.writeAll("DIRC\x00\x00\x00\x02");
    const count = std.math.cast(u32, entries.len) orelse return error.TooManyFiles;
    try bytes.writer.writeInt(u32, count, .big);
    for (entries) |entry| {
        const start = bytes.written().len;
        var header: [62]u8 = @splat(0);
        std.mem.writeInt(u32, header[24..28], entry.mode, .big);
        @memcpy(header[40..60], &entry.oid);
        const length = std.math.cast(u16, @min(entry.path.len, 0xfff)) orelse return error.UnsafeTreePath;
        std.mem.writeInt(u16, header[60..62], length, .big);
        try bytes.writer.writeAll(&header);
        try bytes.writer.writeAll(entry.path);
        try bytes.writer.writeByte(0);
        const remainder = (bytes.written().len - start) % 8;
        if (remainder != 0) try bytes.writer.splatByteAll(0, 8 - remainder);
    }
    var digest: objects.Oid = undefined;
    std.crypto.hash.Sha1.hash(bytes.written(), &digest, .{});
    try bytes.writer.writeAll(&digest);
    try lock.writeStreamingAll(repo.io, bytes.written());
    try lock.sync(repo.io);
    try repo.git.rename("index.lock", repo.git, "index", repo.io);
}

/// Replaces one file atomically; parent traversal never follows symlinks.
pub fn install(repo: Repo, entry: Entry, data: []const u8) !void {
    const p = try parent(repo, entry.path, true);
    defer p.dir.close(repo.io);
    const temporary = try repo.allocator.print(".ugit-{s}.lock", .{p.name});
    defer repo.allocator.free(temporary);
    var renamed = false;
    defer if (!renamed) p.dir.deleteFile(repo.io, temporary) catch |err| std.log.err("remove worktree lock: {s}", .{@errorName(err)});
    if (entry.mode == 0o120000) {
        if (data.len == 0 or data.len > 4096 or std.mem.findScalar(u8, data, 0) != null) return error.InvalidSymlink;
        try p.dir.symLink(repo.io, data, temporary, .{});
    } else {
        const file = try p.dir.createFile(repo.io, temporary, .{ .exclusive = true });
        defer file.close(repo.io);
        try file.writeStreamingAll(repo.io, data);
        try file.setPermissions(repo.io, if (entry.mode == 0o100755) .fromMode(0o755) else .fromMode(0o644));
        try file.sync(repo.io);
    }
    try p.dir.rename(temporary, p.dir, p.name, repo.io);
    renamed = true;
}

test "tree paths cannot target Git metadata or escape worktree" {
    for ([_][]const u8{ ".git/config", "a/.GIT/hooks", "../file", "a//b", "/absolute" }) |path| try std.testing.expect(!validPath(path));
    try std.testing.expect(validPath("src/main.zig"));
}

pub fn fileMode(repo: Repo, path: []const u8) !?u32 {
    const p = parent(repo, path, false) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.SymLinkLoop => return null,
        else => return err,
    };
    defer p.dir.close(repo.io);
    const stat = p.dir.statFile(repo.io, p.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return switch (stat.kind) {
        .sym_link => 0o120000,
        .file => if ((stat.permissions.toMode() & 0o111) != 0) @as(u32, 0o100755) else @as(u32, 0o100644),
        .block_device, .character_device, .directory, .named_pipe, .unix_domain_socket, .whiteout, .door, .event_port, .unknown => null,
    };
}
