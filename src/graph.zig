// SPDX-License-Identifier: GPL-3.0-only
//! Iterative, bounded commit traversal; no runtime recursion.
const std = @import("std");
const Repo = @import("Repo.zig");
const objects = @import("objects.zig");
const Oid = objects.Oid;
pub const max_commits: usize = 100000;
pub const max_parents: usize = 64;

pub const Commit = struct {
    tree: Oid,
    parents: [max_parents]Oid,
    parent_count: usize,
    timestamp: i64,
    author: []const u8,
    message: []const u8,
};

/// Returned slices borrow data. All wire fields are validated before use.
pub fn parseCommit(data: []const u8) !Commit {
    var result: Commit = .{
        .tree = @splat(0),
        .parents = @splat(@splat(0)),
        .parent_count = 0,
        .timestamp = 0,
        .author = "",
        .message = "",
    };
    var has_tree = false;
    var has_author = false;
    var has_committer = false;
    const separator = std.mem.find(u8, data, "\n\n") orelse return error.InvalidCommit;
    result.message = data[separator + 2 ..];
    var lines = std.mem.splitScalar(u8, data[0..separator], '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "tree ")) {
            result.tree = try objects.parseOid(line[5..]);
            has_tree = true;
        } else if (std.mem.startsWith(u8, line, "parent ")) {
            if (result.parent_count == max_parents) return error.TooManyParents;
            result.parents[result.parent_count] = try objects.parseOid(line[7..]);
            result.parent_count += 1;
        } else if (std.mem.startsWith(u8, line, "author ")) {
            const email = std.mem.find(u8, line, " <") orelse return error.InvalidCommit;
            if (email < 7) return error.InvalidCommit;
            result.author = line[7..email];
            has_author = true;
        } else if (std.mem.startsWith(u8, line, "committer ")) {
            const end_email = std.mem.find(u8, line, "> ") orelse return error.InvalidCommit;
            const tail = line[end_email + 2 ..];
            const space = std.mem.findScalar(u8, tail, ' ') orelse return error.InvalidCommit;
            result.timestamp = try std.fmt.parseInt(i64, tail[0..space], 10);
            has_committer = true;
        }
    }
    if (!has_tree or !has_author or !has_committer) return error.InvalidCommit;
    return result;
}

pub fn peel(repo: Repo, start: Oid) !Oid {
    var oid = start;
    for (0..16) |_| {
        const object = try repo.object(oid);
        defer repo.allocator.free(object.data);
        switch (object.kind) {
            .commit => return oid,
            .tag => {
                if (!std.mem.startsWith(u8, object.data, "object ") or object.data.len < 48 or object.data[47] != '\n') return error.InvalidTag;
                oid = try objects.parseOid(object.data[7..47]);
            },
            .blob, .tree => return error.NotCommit,
        }
    }
    return error.TagChainTooDeep;
}

/// Returns owned OIDs, freed by the caller. Includes the starting commit.
pub fn reachable(repo: Repo, start: Oid) ![]Oid {
    var seen: std.AutoHashMapUnmanaged(Oid, void) = .empty;
    defer seen.deinit(repo.allocator);
    var pending: std.ArrayList(Oid) = .empty;
    defer pending.deinit(repo.allocator);
    try pending.append(repo.allocator, try peel(repo, start));
    var cursor: usize = 0;
    while (cursor < pending.items.len) : (cursor += 1) {
        const oid = pending.items[cursor];
        if (seen.contains(oid)) continue;
        if (seen.count() >= max_commits) return error.TooManyCommits;
        try seen.put(repo.allocator, oid, {});
        const object = try repo.object(oid);
        defer repo.allocator.free(object.data);
        if (object.kind != .commit) return error.NotCommit;
        const commit = try parseCommit(object.data);
        for (commit.parents[0..commit.parent_count]) |parent| {
            if (pending.items.len >= max_commits * max_parents) return error.TooManyCommits;
            if (!seen.contains(parent)) try pending.append(repo.allocator, parent);
        }
    }
    const result = try repo.allocator.alloc(Oid, seen.count());
    var keys = seen.keyIterator();
    var index: usize = 0;
    while (keys.next()) |oid| {
        result[index] = oid.*;
        index += 1;
    }
    return result;
}

pub fn contains(repo: Repo, ancestor: Oid, descendant: Oid) !bool {
    const ancestor_commit = try peel(repo, ancestor);
    const commits = try reachable(repo, descendant);
    defer repo.allocator.free(commits);
    for (commits) |oid| if (std.mem.eql(u8, &ancestor_commit, &oid)) return true;
    return false;
}

pub fn differenceCount(repo: Repo, excluded: ?Oid, tip: Oid) !usize {
    const included = try reachable(repo, tip);
    defer repo.allocator.free(included);
    var excluded_set: std.AutoHashMapUnmanaged(Oid, void) = .empty;
    defer excluded_set.deinit(repo.allocator);
    if (excluded) |base| {
        const excluded_oids = try reachable(repo, base);
        defer repo.allocator.free(excluded_oids);
        for (excluded_oids) |oid| try excluded_set.put(repo.allocator, oid, {});
    }
    var count: usize = 0;
    for (included) |oid| if (!excluded_set.contains(oid)) {
        count += 1;
    };
    return count;
}

test "commit parser validates parent fields and borrows metadata" {
    const parsed = try parseCommit("tree 0000000000000000000000000000000000000000\nauthor Test <test@example.invalid> 123 +0000\ncommitter Test <test@example.invalid> 123 +0000\n\nsubject\n\nbody\n");
    try std.testing.expectEqualStrings("Test", parsed.author);
    try std.testing.expectEqual(@as(i64, 123), parsed.timestamp);
    try std.testing.expectEqualStrings("subject\n\nbody\n", parsed.message);
    try std.testing.expectError(error.InvalidCommit, parseCommit("author broken\n\nmessage"));
}
