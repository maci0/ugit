// SPDX-License-Identifier: GPL-3.0-only
//! Updater worktree transitions. Git metadata and worktree paths stay separate.
const std = @import("std");
const Repo = @import("Repo.zig");
const transport = @import("transport.zig");
const graph = @import("graph.zig");
const objects = @import("objects.zig");
const worktree = @import("worktree.zig");

fn oidEqual(a: objects.Oid, b: objects.Oid) bool {
    return std.mem.eql(u8, &a, &b);
}

fn find(entries: []const worktree.Entry, path: []const u8) ?worktree.Entry {
    for (entries) |entry| if (std.mem.eql(u8, entry.path, path)) return entry;
    return null;
}

pub fn reset(repo: Repo, oid: objects.Oid, hard: bool, update_head: bool) !void {
    const index_lock = try repo.git.createFile(repo.io, "index.lock", .{ .exclusive = true });
    defer index_lock.close(repo.io);
    var installed_index = false;
    defer if (!installed_index) repo.git.deleteFile(repo.io, "index.lock") catch |err| std.log.err("remove index lock: {s}", .{@errorName(err)});
    const previous_head = repo.resolve("HEAD") catch |err| switch (err) {
        error.UnknownRef => @as(objects.Oid, @splat(0)),
        else => return err,
    };
    const commit_oid = try graph.peel(repo, oid);
    const target = try worktree.tree(repo, commit_oid);
    defer worktree.free(repo, target);
    const old = try worktree.index(repo);
    defer worktree.free(repo, old);
    // Verify every referenced blob before changing the first file.
    for (target) |entry| {
        const object = try blob(repo, entry.oid);
        defer repo.allocator.free(object.data);
        if (object.kind != .blob) return error.InvalidTree;
        if (!hard) {
            if (find(old, entry.path)) |previous| {
                if (oidEqual(previous.oid, entry.oid) and previous.mode == entry.mode) continue;
                const actual = try worktree.worktreeOid(repo, previous) orelse return error.WorktreeConflict;
                if (!oidEqual(actual, previous.oid)) return error.WorktreeConflict;
            } else {
                const actual = try worktree.worktreeOid(repo, entry);
                if (actual != null) return error.UntrackedConflict;
            }
        }
    }
    for (old) |entry| {
        if (find(target, entry.path) != null) continue;
        if (!hard) {
            const actual = try worktree.worktreeOid(repo, entry) orelse continue;
            if (!oidEqual(actual, entry.oid)) return error.WorktreeConflict;
        }
    }
    for (old) |entry| {
        if (find(target, entry.path) != null) continue;
        const p = worktree.parent(repo, entry.path, false) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => return err,
        };
        defer p.dir.close(repo.io);
        p.dir.deleteFile(repo.io, p.name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    for (target) |entry| {
        if (!hard) {
            if (find(old, entry.path)) |previous| {
                if (oidEqual(previous.oid, entry.oid) and previous.mode == entry.mode) continue;
            }
        }
        const object = try blob(repo, entry.oid);
        defer repo.allocator.free(object.data);
        try worktree.install(repo, entry, object.data);
    }
    try worktree.writeIndex(repo, target, index_lock);
    installed_index = true;
    if (update_head) {
        const head = try repo.head();
        defer if (head) |name| repo.allocator.free(name);
        var buf: [41]u8 = undefined;
        try repo.write(head orelse "HEAD", try std.mem.print(&buf, "{s}\n", .{objects.formatOid(commit_oid)}));
        try headLog(repo, previous_head, commit_oid, "reset: moving to requested revision");
    }
}

pub fn checkout(repo: Repo, name: []const u8) !void {
    const oid = try graph.peel(repo, try repo.resolve(name));
    const previous_oid = try repo.resolve("HEAD");
    const previous_name = try repo.head();
    defer if (previous_name) |value| repo.allocator.free(value);
    const message = try repo.allocator.print("checkout: moving from {s} to {s}", .{ if (previous_name) |value| value[11..] else "HEAD", name });
    defer repo.allocator.free(message);
    try reset(repo, oid, false, false);
    const branch_path = try repo.allocator.print("refs/heads/{s}", .{name});
    defer repo.allocator.free(branch_path);
    const refs = try repo.refs();
    defer repo.freeRefs(refs);
    for (refs) |ref| if (std.mem.eql(u8, ref.name, branch_path)) {
        const head = try repo.allocator.print("ref: {s}\n", .{branch_path});
        defer repo.allocator.free(head);
        try repo.write("HEAD", head);
        try headLog(repo, previous_oid, oid, message);
        return;
    };
    var head_buf: [41]u8 = undefined;
    try repo.write("HEAD", try std.mem.print(&head_buf, "{s}\n", .{objects.formatOid(oid)}));
    try headLog(repo, previous_oid, oid, message);
}

pub fn restore(repo: Repo) !void {
    const entries = try worktree.index(repo);
    defer worktree.free(repo, entries);
    for (entries) |entry| {
        const object = try blob(repo, entry.oid);
        defer repo.allocator.free(object.data);
        if (object.kind != .blob) return error.InvalidTree;
    }
    for (entries) |entry| {
        const object = try blob(repo, entry.oid);
        defer repo.allocator.free(object.data);
        try worktree.install(repo, entry, object.data);
    }
}

pub fn clean(repo: Repo) !void {
    const ignore = @import("ignore.zig");
    const entries = try worktree.index(repo);
    defer worktree.free(repo, entries);
    var walker = try repo.dir.walk(repo.allocator);
    defer Repo.finishWalk(&walker, repo.io);
    var directories: std.ArrayList([]u8) = .empty;
    defer {
        for (directories.items) |path| repo.allocator.free(path);
        directories.deinit(repo.allocator);
    }
    var visits: usize = 0;
    while (try walker.next(repo.io)) |entry| {
        visits += 1;
        if (visits > worktree.max_entries) return error.TooManyFiles;
        if (std.ascii.eqlIgnoreCase(entry.basename, ".git")) {
            if (entry.kind == .directory) walker.leave(repo.io);
            continue;
        }
        if (try ignore.ignored(repo, entry.path, entry.kind == .directory)) {
            if (entry.kind == .directory) walker.leave(repo.io);
            continue;
        }
        if (entry.kind == .directory) {
            const child = try entry.dir.openDir(repo.io, entry.basename, .{ .follow_symlinks = false });
            defer child.close(repo.io);
            if (child.statFile(repo.io, ".git", .{ .follow_symlinks = false })) |_| {
                walker.leave(repo.io);
                continue;
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
            const copy = try repo.allocator.dupe(u8, entry.path);
            errdefer repo.allocator.free(copy);
            try directories.append(repo.allocator, copy);
        } else if (find(entries, entry.path) == null) {
            // The entry's parent handle avoids following a replaced ancestor.
            try entry.dir.deleteFile(repo.io, entry.basename);
        }
    }
    var remaining = directories.items.len;
    while (remaining > 0) {
        remaining -= 1;
        const path = directories.items[remaining];
        const p = try worktree.parent(repo, path, false);
        defer p.dir.close(repo.io);
        p.dir.deleteDir(repo.io, p.name) catch |err| switch (err) {
            error.DirNotEmpty => {},
            else => return err,
        };
    }
}

fn blob(repo: Repo, oid: objects.Oid) !Repo.Object {
    if (repo.object(oid)) |object| return object else |err| switch (err) {
        error.UnknownObject => try transport.fetchMissing(repo, oid),
        else => return err,
    }
    return repo.object(oid);
}

fn headLog(repo: Repo, previous: objects.Oid, current: objects.Oid, message: []const u8) !void {
    const existing = repo.read("logs/HEAD") catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (existing) |bytes| repo.allocator.free(bytes);
    var output: std.Io.Writer.Allocating = .init(repo.allocator);
    defer output.deinit();
    if (existing) |bytes| try output.writer.writeAll(bytes);
    const timestamp = std.Io.Timestamp.now(repo.io, .real).toSeconds();
    try output.writer.print("{s} {s} ugit <ugit@localhost> {d} +0000\t{s}\n", .{ objects.formatOid(previous), objects.formatOid(current), timestamp, message });
    if (output.written().len > Repo.max_file_bytes) return error.ReflogTooLarge;
    try repo.write("logs/HEAD", output.written());
}
