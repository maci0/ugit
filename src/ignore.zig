// SPDX-License-Identifier: GPL-3.0-only
//! Bounded wildcard matching for repository ignore rules.
const std = @import("std");
const Repo = @import("Repo.zig");
const worktree = @import("worktree.zig");
const max_match_steps: usize = 1000000;
const max_match_states: usize = 256;

pub fn matches(pattern: []const u8, path: []const u8) !bool {
    if (pattern.len > 4096 or path.len > 4096) return error.IgnorePatternTooLong;
    const State = struct { pattern: usize, path: usize };
    var states: [max_match_states]State = undefined;
    var count: usize = 1;
    states[0] = .{ .pattern = 0, .path = 0 };
    for (0..max_match_steps) |_| {
        if (count == 0) return false;
        count -= 1;
        var p = states[count].pattern;
        var s = states[count].path;
        while (p < pattern.len) {
            const c = pattern[p];
            if (c == '*') {
                const start = p;
                while (p < pattern.len and pattern[p] == '*') p += 1;
                const cross_slash = p - start >= 2;
                if (count >= states.len) return error.IgnorePatternTooComplex;
                if (s < path.len and (cross_slash or path[s] != '/')) {
                    states[count] = .{ .pattern = start, .path = s + 1 };
                    count += 1;
                }
                if (cross_slash and p < pattern.len and pattern[p] == '/') {
                    if (count >= states.len) return error.IgnorePatternTooComplex;
                    states[count] = .{ .pattern = p + 1, .path = s };
                    count += 1;
                }
                continue;
            }
            if (s >= path.len) break;
            if (c == '?') {
                if (path[s] == '/') break;
                p += 1;
                s += 1;
            } else if (c == '\\') {
                p += 1;
                if (p >= pattern.len or pattern[p] != path[s]) break;
                p += 1;
                s += 1;
            } else if (c == '[') {
                const end = std.mem.findScalarPos(u8, pattern, p + 1, ']') orelse return error.InvalidIgnorePattern;
                var i = p + 1;
                var negate = false;
                if (i < end and (pattern[i] == '!' or pattern[i] == '^')) {
                    negate = true;
                    i += 1;
                }
                var found = false;
                while (i < end) : (i += 1) {
                    if (i + 2 < end and pattern[i + 1] == '-') {
                        if (path[s] >= pattern[i] and path[s] <= pattern[i + 2]) found = true;
                        i += 2;
                    } else if (path[s] == pattern[i]) found = true;
                }
                if (path[s] == '/' or found == negate) break;
                p = end + 1;
                s += 1;
            } else {
                if (c != path[s]) break;
                p += 1;
                s += 1;
            }
        }
        if (p == pattern.len and s == path.len) return true;
    }
    return error.IgnorePatternTooComplex;
}

fn rules(bytes: []const u8, path: []const u8, directory: bool, previous: bool) !bool {
    var result = previous;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        var pattern = std.mem.trimEnd(u8, raw, "\r ");
        if (pattern.len == 0 or pattern[0] == '#') continue;
        const negate = pattern[0] == '!';
        if (negate) pattern = pattern[1..];
        if (pattern.len == 0) continue;
        const dir_only = pattern[pattern.len - 1] == '/';
        if (dir_only) pattern = pattern[0 .. pattern.len - 1];
        if (dir_only and !directory) continue;
        const anchored = pattern.len > 0 and pattern[0] == '/';
        if (anchored) pattern = pattern[1..];
        // misra-lint: allow deprecated_api std.fs.path.basename is current; this is not deprecated std.Io.Dir.path.
        const candidate = if (!anchored and std.mem.findScalar(u8, pattern, '/') == null) std.fs.path.basename(path) else path;
        if (try matches(pattern, candidate)) result = !negate;
    }
    return result;
}

pub fn ignored(repo: Repo, path: []const u8, directory: bool) !bool {
    var result = false;
    const exclude = repo.read("info/exclude") catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (exclude) |bytes| {
        defer repo.allocator.free(bytes);
        result = try rules(bytes, path, directory, result);
    }
    var base: usize = 0;
    for (0..256) |_| {
        const ignore_path = try repo.allocator.print("{s}.gitignore", .{path[0..base]});
        defer repo.allocator.free(ignore_path);
        const p = worktree.parent(repo, ignore_path, false) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.SymLinkLoop => return result,
            else => return err,
        };
        defer p.dir.close(repo.io);
        const bytes = p.dir.readFileAlloc(repo.io, p.name, repo.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (bytes) |data| {
            defer repo.allocator.free(data);
            result = try rules(data, path[base..], directory, result);
        }
        const slash = std.mem.findScalarPos(u8, path, base, '/') orelse return result;
        base = slash + 1;
    }
    return error.PathTooDeep;
}

test "wildcards distinguish path separators and recursive patterns" {
    try std.testing.expect(try matches("*.zig", "main.zig"));
    try std.testing.expect(!try matches("*.zig", "src/main.zig"));
    try std.testing.expect(try matches("**/*.zig", "main.zig"));
    try std.testing.expect(try matches("**/*.zig", "src/a/main.zig"));
    try std.testing.expect(try matches("[a-c]?.zig", "ab.zig"));
    try std.testing.expect(!try matches("[!a-c]*", "abc"));
    try std.testing.expect(try matches("\\#file", "#file"));
}

test "ignore rules respect negation anchors and directories" {
    try std.testing.expect(try rules("*.zig\n!keep.zig\n", "foo.zig", false, false));
    try std.testing.expect(!try rules("*.zig\n!keep.zig\n", "keep.zig", false, false));
    try std.testing.expect(!try rules("/build/\n", "src/build", true, false));
    try std.testing.expect(try rules("build/\n", "src/build", true, false));
}
