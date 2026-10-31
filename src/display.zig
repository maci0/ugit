// SPDX-License-Identifier: GPL-3.0-only
//! The updater's version, changelog and tag output formats.
const std = @import("std");
const Repo = @import("Repo.zig");
const objects = @import("objects.zig");
const graph = @import("graph.zig");
const worktree = @import("worktree.zig");

pub const log_format: []const u8 = "sha:%H%x1Dauthor:%an%x1Ddate:%ct%x1Dsubject:%s%x1Dmessage:%b%x1E";
pub const ref_format: []const u8 = "%(if)%(*objecttype)%(then)%(*objecttype) %(*objectname)%(else)%(objecttype) %(objectname)%(end) %(refname)";

fn dirty(repo: Repo) !bool {
    const index = try worktree.index(repo);
    defer worktree.free(repo, index);
    const head = try worktree.tree(repo, try repo.resolve("HEAD"));
    defer worktree.free(repo, head);
    if (index.len != head.len) return true;
    for (index, head) |entry, original| {
        if (!std.mem.eql(u8, entry.path, original.path) or !std.mem.eql(u8, &entry.oid, &original.oid) or entry.mode != original.mode) return true;
        const actual_mode = try worktree.fileMode(repo, entry.path) orelse return true;
        if (actual_mode != entry.mode) return true;
        const actual = try worktree.worktreeOid(repo, entry) orelse return true;
        if (!std.mem.eql(u8, &actual, &entry.oid)) return true;
    }
    return false;
}

fn has(args: []const []const u8, expected: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, expected)) return true;
    return false;
}

pub fn describe(repo: Repo, args: []const []const u8, out: *std.Io.Writer) !void {
    var name: []const u8 = "HEAD";
    var abbrev: usize = 7;
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--abbrev=")) {
            abbrev = try std.fmt.parseInt(usize, arg[9..], 10);
            if (abbrev == 0 or abbrev > 40) return error.InvalidArguments;
        } else if (arg[0] != '-') name = arg;
    }
    const oid = try graph.peel(repo, try repo.resolve(name));
    const refs = try repo.refs();
    defer repo.freeRefs(refs);
    var best: ?[]const u8 = null;
    var best_count: usize = graph.max_commits;
    var best_annotated = false;
    var best_timestamp: i64 = std.math.minInt(i64);
    std.mem.sort(Repo.Ref, refs, {}, struct {
        fn less(_: void, a: Repo.Ref, b: Repo.Ref) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);
    for (refs) |ref| {
        if (!std.mem.startsWith(u8, ref.name, "refs/tags/")) continue;
        const tagged = graph.peel(repo, ref.oid) catch |err| switch (err) {
            error.NotCommit => continue,
            else => return err,
        };
        if (!try graph.contains(repo, tagged, oid)) continue;
        const distance = try graph.differenceCount(repo, tagged, oid);
        const object = try repo.object(ref.oid);
        defer repo.allocator.free(object.data);
        const annotated = object.kind == .tag;
        const timestamp = if (annotated) try tagTimestamp(object.data) else 0;
        const preferred_tag = annotated and (!best_annotated or timestamp > best_timestamp);
        if (best == null or distance < best_count or (distance == best_count and preferred_tag)) {
            best = ref.name[10..];
            best_count = distance;
            best_annotated = annotated;
            best_timestamp = timestamp;
        }
    }
    if (best) |tag| {
        try out.writeAll(tag);
        if (best_count != 0 or has(args, "--long")) try out.print("-{d}-g{s}", .{ best_count, objects.formatOid(oid)[0..abbrev] });
    } else if (has(args, "--always")) {
        try out.writeAll(objects.formatOid(oid)[0..abbrev]);
    } else return error.NoTags;
    if (has(args, "--dirty") and try dirty(repo)) try out.writeAll("-dirty");
    try out.writeByte('\n');
}

pub fn log(repo: Repo, args: []const []const u8, out: *std.Io.Writer) !void {
    var expression: []const u8 = "";
    var limit: usize = 100;
    for (args) |arg| {
        if (arg[0] != '-') expression = arg else if (std.mem.startsWith(u8, arg, "--format=")) {
            if (!std.mem.eql(u8, arg[9..], log_format)) return error.UnsupportedFormat;
        } else if (std.mem.startsWith(u8, arg, "--max-count=")) {
            limit = try std.fmt.parseInt(usize, arg[12..], 10);
            if (limit > graph.max_commits) return error.TooManyCommits;
        }
    }
    const dots = std.mem.find(u8, expression, "..") orelse return error.InvalidArguments;
    const base = try repo.resolve(expression[0..dots]);
    const tip = try repo.resolve(expression[dots + 2 ..]);
    const excluded = try graph.reachable(repo, base);
    defer repo.allocator.free(excluded);
    var seen: std.AutoHashMapUnmanaged(objects.Oid, void) = .empty;
    defer seen.deinit(repo.allocator);
    for (excluded) |oid| try seen.put(repo.allocator, oid, {});
    const Node = struct { oid: objects.Oid, time: i64 };
    var queue: std.ArrayList(Node) = .empty;
    defer queue.deinit(repo.allocator);
    try queue.append(repo.allocator, .{ .oid = tip, .time = 0 });
    var emitted: usize = 0;
    for (0..graph.max_commits) |_| {
        if (queue.items.len == 0 or emitted >= limit) return;
        var selected: usize = 0;
        for (queue.items, 0..) |node, i| if (node.time > queue.items[selected].time) {
            selected = i;
        };
        const node = queue.swapRemove(selected);
        if (seen.contains(node.oid)) continue;
        try seen.put(repo.allocator, node.oid, {});
        const object = try repo.object(node.oid);
        defer repo.allocator.free(object.data);
        const commit = try graph.parseCommit(object.data);
        const end_subject = std.mem.find(u8, commit.message, "\n\n") orelse commit.message.len;
        const subject = std.mem.trim(u8, commit.message[0..end_subject], "\n");
        const body = if (end_subject < commit.message.len) commit.message[end_subject + 2 ..] else "";
        try out.print("sha:{s}\x1dauthor:{s}\x1ddate:{d}\x1dsubject:", .{ objects.formatOid(node.oid), commit.author, commit.timestamp });
        for (subject) |byte| try out.writeByte(if (byte == '\n') ' ' else byte);
        try out.print("\x1dmessage:{s}\x1e\n", .{body});
        emitted += 1;
        for (commit.parents[0..commit.parent_count]) |parent| {
            if (seen.contains(parent)) continue;
            if (queue.items.len >= graph.max_commits) return error.TooManyCommits;
            const parent_object = try repo.object(parent);
            defer repo.allocator.free(parent_object.data);
            const parent_commit = try graph.parseCommit(parent_object.data);
            try queue.append(repo.allocator, .{ .oid = parent, .time = parent_commit.timestamp });
        }
    }
    return error.TooManyCommits;
}

pub fn tags(repo: Repo, args: []const []const u8, out: *std.Io.Writer) !void {
    var count: usize = 100;
    var contains: []const u8 = "HEAD";
    var merged: []const u8 = "HEAD";
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--count=")) count = try std.fmt.parseInt(usize, arg[8..], 10) else if (std.mem.startsWith(u8, arg, "--contains=")) contains = arg[11..] else if (std.mem.startsWith(u8, arg, "--merged=")) merged = arg[9..] else if (std.mem.startsWith(u8, arg, "--format=")) {
            if (!std.mem.eql(u8, arg[9..], ref_format)) return error.UnsupportedFormat;
        } else if (std.mem.startsWith(u8, arg, "--sort=")) {
            if (!std.mem.eql(u8, arg[7..], "-creatordate")) return error.UnsupportedSort;
        } else if (!std.mem.eql(u8, arg, "refs/tags")) return error.InvalidArguments;
    }
    if (count == 0) count = Repo.max_refs;
    if (count > Repo.max_refs) return error.TooManyRefs;
    const start = try repo.resolve(contains);
    const tip = try repo.resolve(merged);
    const refs = try repo.refs();
    defer repo.freeRefs(refs);
    const Tag = struct { ref: Repo.Ref, commit: objects.Oid, time: i64 };
    var selected: std.ArrayList(Tag) = .empty;
    defer selected.deinit(repo.allocator);
    for (refs) |ref| {
        if (!std.mem.startsWith(u8, ref.name, "refs/tags/")) continue;
        const commit_oid = graph.peel(repo, ref.oid) catch |err| switch (err) {
            error.NotCommit => continue,
            else => return err,
        };
        if (!try graph.contains(repo, start, commit_oid) or !try graph.contains(repo, commit_oid, tip)) continue;
        const object = try repo.object(ref.oid);
        defer repo.allocator.free(object.data);
        var timestamp: i64 = 0;
        if (object.kind == .tag) timestamp = try tagTimestamp(object.data) else timestamp = (try graph.parseCommit(object.data)).timestamp;
        try selected.append(repo.allocator, .{ .ref = ref, .commit = commit_oid, .time = timestamp });
    }
    std.mem.sort(Tag, selected.items, {}, struct {
        fn less(_: void, a: Tag, b: Tag) bool {
            if (a.time != b.time) return a.time > b.time;
            return std.mem.order(u8, a.ref.name, b.ref.name) == .lt;
        }
    }.less);
    for (selected.items[0..@min(count, selected.items.len)]) |tag| try out.print("commit {s} {s}\n", .{ objects.formatOid(tag.commit), tag.ref.name });
}

fn tagTimestamp(data: []const u8) !i64 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "tagger ")) continue;
        const end_email = std.mem.find(u8, line, "> ") orelse return error.InvalidTag;
        const tail = line[end_email + 2 ..];
        const space = std.mem.findScalar(u8, tail, ' ') orelse return error.InvalidTag;
        return std.fmt.parseInt(i64, tail[0..space], 10);
    }
    return 0;
}
