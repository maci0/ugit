// SPDX-License-Identifier: GPL-3.0-only
const config_file = @import("config.zig");
const std = @import("std");
const Repo = @import("Repo.zig");
const cli = @import("cli.zig");
const display = @import("display.zig");
const mutate = @import("mutate.zig");
const transport = @import("transport.zig");
const ignore = @import("ignore.zig");
const worktree = @import("worktree.zig");
const graph = @import("graph.zig");
const objects = @import("objects.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, invocation: cli.Invocation, output: *std.Io.Writer) !u8 {
    if (invocation.command == .clone) return clone(allocator, io, invocation);
    const repo = try Repo.open(allocator, io, invocation.directory);
    defer repo.close();
    switch (invocation.command) {
        .rev_parse => {
            const args = invocation.args;
            if (std.mem.eql(u8, args[0], "--abbrev-ref")) {
                const head = try repo.head();
                defer if (head) |value| allocator.free(value);
                if (head) |value| {
                    const name = if (std.mem.startsWith(u8, value, "refs/heads/")) value[11..] else value;
                    try output.print("{s}\n", .{name});
                } else try output.writeAll("HEAD\n");
            } else try output.print("{s}\n", .{objects.formatOid(try repo.resolve(args[0]))});
        },
        .remote => {
            const config = try repo.read("config");
            defer allocator.free(config);
            if (invocation.args.len == 0) {
                var lines = std.mem.splitScalar(u8, config, '\n');
                while (lines.next()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t\r");
                    if (std.mem.startsWith(u8, trimmed, "[remote \"") and std.mem.endsWith(u8, trimmed, "\"]")) {
                        try output.print("{s}\n", .{trimmed[9 .. trimmed.len - 2]});
                    }
                }
            } else if (std.mem.eql(u8, invocation.args[0], "get-url")) {
                const section = try allocator.print("remote \"{s}\"", .{invocation.args[1]});
                defer allocator.free(section);
                const value = config_file.value(config, section, "url") orelse return error.UnknownRemote;
                try output.print("{s}\n", .{value});
            } else {
                try setRemoteUrl(repo, invocation.args[1], invocation.args[2]);
            }
        },
        .cat_file => {
            const object = try repo.object(try graph.peel(repo, try repo.resolve(invocation.args[1])));
            defer allocator.free(object.data);
            if (object.kind != .commit) return error.NotCommit;
        },
        .merge_base => return if (try graph.contains(repo, try repo.resolve(invocation.args[1]), try repo.resolve(invocation.args[2]))) 0 else 1,
        .rev_list => {
            if (invocation.args.len == 2 and std.mem.eql(u8, invocation.args[0], "--tags")) {
                try latestTaggedCommit(repo, output);
                return 0;
            }
            var expression: []const u8 = "HEAD";
            for (invocation.args) |arg| if (!std.mem.startsWith(u8, arg, "--")) {
                expression = arg;
            };
            const count = if (std.mem.find(u8, expression, "..")) |dots|
                try graph.differenceCount(repo, try repo.resolve(expression[0..dots]), try repo.resolve(expression[dots + 2 ..]))
            else
                try graph.differenceCount(repo, null, try repo.resolve(expression));
            try output.print("{d}\n", .{count});
        },
        .branch => {
            const current = try repo.head();
            defer if (current) |name| allocator.free(name);
            const refs = try repo.refs();
            defer repo.freeRefs(refs);
            std.mem.sort(Repo.Ref, refs, {}, struct {
                fn less(_: void, a: Repo.Ref, b: Repo.Ref) bool {
                    return std.mem.order(u8, a.name, b.name) == .lt;
                }
            }.less);
            if (current == null) {
                const label = try detachedLabel(repo);
                defer allocator.free(label.name);
                try output.print("* (HEAD detached {s} {s})\n", .{ if (label.at) "at" else "from", label.name });
            }
            for (refs) |ref| {
                if (!std.mem.startsWith(u8, ref.name, "refs/heads/")) continue;
                const selected = if (current) |name| std.mem.eql(u8, name, ref.name) else false;
                const prefix: []const u8 = if (selected) "* " else if (try checkedOutElsewhere(repo, ref.name)) "+ " else "  ";
                try output.print("{s}{s}\n", .{ prefix, ref.name[11..] });
            }
        },
        .status => {
            const entries = try worktree.index(repo);
            defer worktree.free(repo, entries);
            for (invocation.args) |arg| if (std.mem.eql(u8, arg, "-b")) {
                const current = try repo.head();
                defer if (current) |name| allocator.free(name);
                try branchStatus(repo, current, output);
            };
            const head_entries = try worktree.tree(repo, try repo.resolve("HEAD"));
            defer worktree.free(repo, head_entries);
            for (entries) |entry| {
                var stage: u8 = 'A';
                for (head_entries) |head_entry| {
                    if (std.mem.eql(u8, entry.path, head_entry.path)) {
                        stage = if (std.mem.eql(u8, &entry.oid, &head_entry.oid) and entry.mode == head_entry.mode) ' ' else 'M';
                        break;
                    }
                }
                const actual = try worktree.worktreeOid(repo, entry);
                const actual_mode = try worktree.fileMode(repo, entry.path);
                const marker: u8 = if (actual_mode) |value| (if ((value & 0o170000) != (entry.mode & 0o170000)) 'T' else if (value != entry.mode) 'M' else if (actual) |hash| (if (std.mem.eql(u8, &hash, &entry.oid)) ' ' else 'M') else 'D') else 'D';
                if (marker != ' ' or stage != ' ') {
                    try output.print("{c}{c} ", .{ stage, marker });
                    try writePath(output, entry.path);
                    try output.writeByte('\n');
                }
            }
            for (head_entries) |head_entry| {
                var found = false;
                for (entries) |entry| if (std.mem.eql(u8, head_entry.path, entry.path)) {
                    found = true;
                    break;
                };
                if (!found) {
                    try output.writeAll("D  ");
                    try writePath(output, head_entry.path);
                    try output.writeByte('\n');
                }
            }
            var show_ignored = false;
            for (invocation.args) |arg| if (std.mem.eql(u8, arg, "--ignored")) {
                show_ignored = true;
            };
            var ignored_paths: std.ArrayList([]u8) = .empty;
            defer {
                for (ignored_paths.items) |path| allocator.free(path);
                ignored_paths.deinit(allocator);
            }
            var untracked: std.ArrayList([]u8) = .empty;
            defer {
                for (untracked.items) |path| allocator.free(path);
                untracked.deinit(allocator);
            }
            var walker = try repo.dir.walk(allocator);
            defer Repo.finishWalk(&walker, io);
            var visited: usize = 0;
            while (try walker.next(io)) |entry| {
                visited += 1;
                if (visited > worktree.max_entries) return error.TooManyFiles;
                if (std.ascii.eqlIgnoreCase(entry.basename, ".git")) {
                    if (entry.kind == .directory) walker.leave(io);
                    continue;
                }
                var tracked = false;
                for (entries) |item| if (std.mem.eql(u8, entry.path, item.path)) {
                    tracked = true;
                    break;
                };
                if (tracked) continue;
                if (try ignore.ignored(repo, entry.path, entry.kind == .directory)) {
                    if (show_ignored) {
                        try ignored_paths.ensureUnusedCapacity(allocator, 1);
                        const path = try allocator.print("{s}{s}", .{ entry.path, if (entry.kind == .directory) "/" else "" });
                        ignored_paths.appendAssumeCapacity(path);
                    }
                    if (entry.kind == .directory) walker.leave(io);
                    continue;
                }
                if (entry.kind == .directory) {
                    var tracked_descendant = false;
                    for (entries) |item| if (std.mem.startsWith(u8, item.path, entry.path) and item.path.len > entry.path.len and item.path[entry.path.len] == '/') {
                        tracked_descendant = true;
                        break;
                    };
                    if (!tracked_descendant and try hasUntrackedFile(repo, entry.path)) {
                        try untracked.ensureUnusedCapacity(allocator, 1);
                        const path = try allocator.print("{s}/", .{entry.path});
                        untracked.appendAssumeCapacity(path);
                        walker.leave(io);
                    }
                } else {
                    try untracked.ensureUnusedCapacity(allocator, 1);
                    const path = try allocator.dupe(u8, entry.path);
                    untracked.appendAssumeCapacity(path);
                }
            }
            const Order = struct {
                fn less(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            };
            std.mem.sort([]u8, untracked.items, {}, Order.less);
            std.mem.sort([]u8, ignored_paths.items, {}, Order.less);
            for (untracked.items) |path| {
                try output.writeAll("?? ");
                try writePath(output, path);
                try output.writeByte('\n');
            }
            for (ignored_paths.items) |path| {
                try output.writeAll("!! ");
                try writePath(output, path);
                try output.writeByte('\n');
            }
        },
        .fetch => {
            const config = try repo.read("config");
            defer allocator.free(config);
            var remote_name: []const u8 = "origin";
            var prune = false;
            var all = false;
            for (invocation.args) |arg| {
                if (arg[0] != '-') remote_name = arg;
                if (std.mem.eql(u8, arg, "--prune") or std.mem.eql(u8, arg, "-p")) prune = true;
                if (std.mem.eql(u8, arg, "--all")) all = true;
            }
            if (all) {
                var lines = std.mem.splitScalar(u8, config, '\n');
                while (lines.next()) |raw| {
                    const line = std.mem.trim(u8, raw, " \t\r");
                    if (!std.mem.startsWith(u8, line, "[remote \"") or !std.mem.endsWith(u8, line, "\"]")) continue;
                    const name = line[9 .. line.len - 2];
                    const url = config_file.value(config, line[1 .. line.len - 1], "url") orelse return error.UnknownRemote;
                    try transport.fetch(repo, url, name, prune);
                }
                return 0;
            }
            const section = try allocator.print("remote \"{s}\"", .{remote_name});
            defer allocator.free(section);
            const url = config_file.value(config, section, "url") orelse return error.UnknownRemote;
            try transport.fetch(repo, url, remote_name, prune);
        },
        .reset => try mutate.reset(repo, try repo.resolve(invocation.args[1]), true, true),
        .checkout => {
            const args = invocation.args;
            if (args.len == 3) try mutate.restore(repo) else {
                const target_name = args[args.len - 1];
                const target_branch = try allocator.print("refs/heads/{s}", .{target_name});
                defer allocator.free(target_branch);
                const current = try repo.head();
                defer if (current) |name| allocator.free(name);
                const already_current = if (current) |name| std.mem.eql(u8, name, target_branch) else false;
                if (!already_current and try checkedOutElsewhere(repo, target_branch)) return error.BranchInUse;
                try mutate.checkout(repo, target_name);
            }
        },
        .describe => try display.describe(repo, invocation.args, output),
        .log => try display.log(repo, invocation.args, output),
        .for_each_ref => try display.tags(repo, invocation.args, output),
        .config => {
            try configCommand(repo, invocation.args, output);
        },
        .clean => try mutate.clean(repo),
        .pull => {
            const config = try repo.read("config");
            defer allocator.free(config);
            const head = try repo.head() orelse return error.DetachedHead;
            defer allocator.free(head);
            const tracking_section = try allocator.print("branch \"{s}\"", .{head[11..]});
            defer allocator.free(tracking_section);
            var remote_name: []const u8 = config_file.value(config, tracking_section, "remote") orelse "origin";
            const merge_ref = config_file.value(config, tracking_section, "merge");
            const tracking_branch = if (merge_ref) |ref| (if (std.mem.startsWith(u8, ref, "refs/heads/")) ref[11..] else return error.InvalidConfig) else head[11..];
            var ref_name: ?[]const u8 = null;
            for (invocation.args) |arg| if (arg[0] != '-') {
                if (ref_name == null) {
                    remote_name = arg;
                    ref_name = "";
                } else ref_name = arg;
            };
            const remote_section = try allocator.print("remote \"{s}\"", .{remote_name});
            defer allocator.free(remote_section);
            const url = config_file.value(config, remote_section, "url") orelse return error.UnknownRemote;
            try transport.fetch(repo, url, remote_name, false);
            const branch_ref = try allocator.print("{s}/{s}", .{ remote_name, tracking_branch });
            defer allocator.free(branch_ref);
            const target = try repo.resolve(if (ref_name) |ref| (if (ref.len > 0) ref else branch_ref) else branch_ref);
            const current = try repo.resolve("HEAD");
            if (!try graph.contains(repo, current, target)) return error.NonFastForward;
            try mutate.reset(repo, target, false, true);
        },
        .clone => return error.InvalidArguments,
        .fsck => try fsck(repo),
    }
    return 0;
}

fn clone(allocator: std.mem.Allocator, io: std.Io, invocation: cli.Invocation) !u8 {
    const args = invocation.args;
    const branch_ref = try allocator.print("refs/heads/{s}", .{args[1]});
    defer allocator.free(branch_ref);
    if (!Repo.validRef(branch_ref) or std.mem.findScalar(u8, args[1], '"') != null) return error.InvalidRef;
    const uri = try std.Uri.parse(args[3]);
    if (uri.user != null or uri.password != null) return error.UnsupportedCredentials;
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) return error.UnsupportedTransport;
    if (std.mem.findAny(u8, args[3], "\n\r") != null) return error.InvalidRemote;
    const parent_dir = try std.Io.Dir.cwd().openDir(io, invocation.directory, .{});
    defer parent_dir.close(io);
    try parent_dir.createDir(io, args[4], .default_dir);
    const destination = try parent_dir.openDir(io, args[4], .{});
    defer destination.close(io);
    try destination.createDirPath(io, ".git/objects");
    try destination.createDirPath(io, ".git/refs/heads");
    const git_dir = try destination.openDir(io, ".git", .{});
    defer git_dir.close(io);
    if (!Repo.validPath(args[1]) or std.mem.findScalar(u8, args[1], '\n') != null) return error.InvalidRef;
    const config = try allocator.print("[core]\n\trepositoryformatversion = 1\n\tbare = false\n[extensions]\n\tpartialClone = origin\n[remote \"origin\"]\n\turl = {s}\n\tpromisor = true\n\tpartialclonefilter = blob:none\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n[branch \"{s}\"]\n\tremote = origin\n\tmerge = refs/heads/{s}\n", .{ args[3], args[1], args[1] });
    defer allocator.free(config);
    if (std.mem.findScalar(u8, args[3], '\n') != null or std.mem.findScalar(u8, args[3], '\r') != null) return error.InvalidRemote;
    try git_dir.writeFile(io, .{ .sub_path = "config", .data = config });
    const head = try allocator.print("ref: refs/heads/{s}\n", .{args[1]});
    defer allocator.free(head);
    try git_dir.writeFile(io, .{ .sub_path = "HEAD", .data = head });
    // misra-lint: allow deprecated_api std.fs.path.isAbsolute is current; this is not deprecated std.Io.Dir.path.
    const path = if (std.fs.path.isAbsolute(args[4])) try allocator.dupe(u8, args[4]) else try allocator.print("{s}/{s}", .{ invocation.directory, args[4] });
    defer allocator.free(path);
    const repo = try Repo.open(allocator, io, path);
    defer repo.close();
    try transport.fetch(repo, args[3], "origin", false);
    const remote_ref = try allocator.print("origin/{s}", .{args[1]});
    defer allocator.free(remote_ref);
    try mutate.reset(repo, try repo.resolve(remote_ref), true, true);
    return 0;
}

fn configCommand(repo: Repo, args: []const []const u8, out: *std.Io.Writer) !void {
    var key: []const u8 = "";
    for (args) |arg| if (arg[0] != '-') {
        key = arg;
        break;
    };
    const first = std.mem.findScalar(u8, key, '.') orelse return error.InvalidArguments;
    const last = std.mem.findScalarLast(u8, key, '.') orelse return error.InvalidArguments;
    const section = if (first == last) try repo.allocator.dupe(u8, key[0..first]) else try repo.allocator.print("{s} \"{s}\"", .{ key[0..first], key[first + 1 .. last] });
    defer repo.allocator.free(section);
    const config = try repo.read("config");
    defer repo.allocator.free(config);
    const value = config_file.value(config, section, key[last + 1 ..]) orelse return error.ConfigNotFound;
    try out.print("{s}\n", .{value});
}

fn fsck(repo: Repo) !void {
    const head_ref = try repo.head();
    defer if (head_ref) |name| repo.allocator.free(name);
    const head_oid = repo.resolve("HEAD") catch |err| switch (err) {
        error.UnknownRef => if (head_ref != null) null else return err,
        else => return err,
    };
    if (head_oid) |oid| try checkObjectLink(repo, oid, .commit, false);
    const promisor = try repo.hasPromisorPacks();
    const oids = try repo.allOids();
    defer repo.allocator.free(oids);
    for (oids) |oid| {
        const object = try repo.object(oid);
        defer repo.allocator.free(object.data);
        switch (object.kind) {
            .blob => {},
            .commit => {
                const commit = try graph.parseCommit(object.data);
                try checkObjectLink(repo, commit.tree, .tree, false);
                for (commit.parents[0..commit.parent_count]) |parent| try checkObjectLink(repo, parent, .commit, false);
            },
            .tree => try checkTreeLinks(repo, object.data, promisor),
            .tag => {
                if (object.data.len < 48 or !std.mem.startsWith(u8, object.data, "object ") or object.data[47] != '\n') return error.InvalidTag;
                var lines = std.mem.splitScalar(u8, object.data[48..], '\n');
                const type_line = lines.next() orelse return error.InvalidTag;
                if (!std.mem.startsWith(u8, type_line, "type ")) return error.InvalidTag;
                const kind = std.meta.stringToEnum(objects.Kind, type_line[5..]) orelse return error.InvalidTag;
                try checkObjectLink(repo, try objects.parseOid(object.data[7..47]), kind, promisor and kind == .blob);
            },
        }
    }
    const refs = try repo.refs();
    defer repo.freeRefs(refs);
    for (refs) |ref| {
        const object = try repo.object(ref.oid);
        repo.allocator.free(object.data);
    }
}

fn checkObjectLink(repo: Repo, oid: objects.Oid, kind: objects.Kind, promised: bool) !void {
    const object = repo.object(oid) catch |err| switch (err) {
        error.UnknownObject => if (promised) return else return err,
        else => return err,
    };
    defer repo.allocator.free(object.data);
    if (object.kind != kind) return error.InvalidObject;
}

fn checkTreeLinks(repo: Repo, data: []const u8, promisor: bool) !void {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(repo.allocator);
    var offset: usize = 0;
    while (offset < data.len) {
        const rest = data[offset..];
        const space = std.mem.findScalar(u8, rest, ' ') orelse return error.InvalidTree;
        const zero = std.mem.findScalar(u8, rest, 0) orelse return error.InvalidTree;
        if (zero <= space or rest.len - zero - 1 < 20) return error.InvalidTree;
        const name = rest[space + 1 .. zero];
        if (!worktree.validPath(name) or std.mem.findScalar(u8, name, '/') != null) return error.InvalidTree;
        if (names.count() >= worktree.max_entries) return error.TooManyFiles;
        if (names.contains(name)) return error.InvalidTree;
        try names.put(repo.allocator, name, {});
        const mode = try std.fmt.parseInt(u32, rest[0..space], 8);
        const oid: objects.Oid = rest[zero + 1 ..][0..20].*;
        switch (mode) {
            0o40000 => try checkObjectLink(repo, oid, .tree, false),
            0o100644, 0o100755, 0o120000 => try checkObjectLink(repo, oid, .blob, promisor),
            0o160000 => {},
            else => return error.InvalidTree,
        }
        offset += zero + 21;
    }
}

fn setRemoteUrl(repo: Repo, name: []const u8, url: []const u8) !void {
    if (std.mem.findAny(u8, url, "\n\r\"\\#; \t") != null) return error.InvalidRemote;
    const expected = try repo.allocator.print("remote \"{s}\"", .{name});
    defer repo.allocator.free(expected);
    const bytes = try repo.read("config");
    defer repo.allocator.free(bytes);
    var output: std.Io.Writer.Allocating = .init(repo.allocator);
    defer output.deinit();
    var active = false;
    var replaced = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0 and line[0] == '[') active = std.mem.endsWith(u8, line, "]") and std.mem.eql(u8, line[1 .. line.len - 1], expected);
        if (active) {
            if (std.mem.findScalar(u8, line, '=')) |equal| {
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..equal], " \t"), "url")) {
                    try output.writer.print("\turl = {s}\n", .{url});
                    replaced = true;
                    continue;
                }
            }
        }
        try output.writer.print("{s}\n", .{raw});
    }
    if (!replaced) return error.UnknownRemote;
    try repo.write("config", output.written());
}

fn branchStatus(repo: Repo, current: ?[]const u8, out: *std.Io.Writer) !void {
    const name = current orelse {
        try out.writeAll("## HEAD (no branch)\n");
        return;
    };
    const branch = name[11..];
    try out.print("## {s}", .{branch});
    const config = try repo.read("config");
    defer repo.allocator.free(config);
    const section = try repo.allocator.print("branch \"{s}\"", .{branch});
    defer repo.allocator.free(section);
    if (config_file.value(config, section, "remote")) |remote| {
        if (config_file.value(config, section, "merge")) |merge| {
            if (!std.mem.startsWith(u8, merge, "refs/heads/")) return error.InvalidConfig;
            const upstream = try repo.allocator.print("{s}/{s}", .{ remote, merge[11..] });
            defer repo.allocator.free(upstream);
            try out.print("...{s}", .{upstream});
            const upstream_oid = repo.resolve(upstream) catch |err| switch (err) {
                error.UnknownRef => {
                    try out.writeAll(" [gone]\n");
                    return;
                },
                else => return err,
            };
            const head_oid = try repo.resolve("HEAD");
            const ahead = try graph.differenceCount(repo, upstream_oid, head_oid);
            const behind = try graph.differenceCount(repo, head_oid, upstream_oid);
            if (ahead != 0 or behind != 0) {
                try out.writeAll(" [");
                if (ahead != 0) try out.print("ahead {d}", .{ahead});
                if (ahead != 0 and behind != 0) try out.writeAll(", ");
                if (behind != 0) try out.print("behind {d}", .{behind});
                try out.writeByte(']');
            }
        }
    }
    try out.writeByte('\n');
}

fn hasUntrackedFile(repo: Repo, path: []const u8) !bool {
    const dir = try repo.dir.openDir(repo.io, path, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(repo.io);
    var walker = try dir.walk(repo.allocator);
    defer Repo.finishWalk(&walker, repo.io);
    var count: usize = 0;
    while (try walker.next(repo.io)) |entry| {
        count += 1;
        if (count > worktree.max_entries) return error.TooManyFiles;
        const full = try repo.allocator.print("{s}/{s}", .{ path, entry.path });
        defer repo.allocator.free(full);
        if (try ignore.ignored(repo, full, entry.kind == .directory)) {
            if (entry.kind == .directory) walker.leave(repo.io);
            continue;
        }
        if (entry.kind != .directory) return true;
    }
    return false;
}

fn checkedOutElsewhere(repo: Repo, ref: []const u8) !bool {
    const original_head = try repo.common.readFileAlloc(repo.io, "HEAD", repo.allocator, .limited(4096));
    defer repo.allocator.free(original_head);
    if (std.mem.startsWith(u8, original_head, "ref: ") and std.mem.eql(u8, std.mem.trimEnd(u8, original_head[5..], "\r\n"), ref)) return true;
    const dir = repo.common.openDir(repo.io, "worktrees", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer dir.close(repo.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(repo.io)) |entry| {
        count += 1;
        if (count > 1024) return error.TooManyWorktrees;
        if (entry.kind != .directory) continue;
        const path = try repo.allocator.print("{s}/HEAD", .{entry.name});
        defer repo.allocator.free(path);
        const head = try dir.readFileAlloc(repo.io, path, repo.allocator, .limited(4096));
        defer repo.allocator.free(head);
        if (std.mem.startsWith(u8, head, "ref: ") and std.mem.eql(u8, std.mem.trimEnd(u8, head[5..], "\r\n"), ref)) return true;
    }
    return false;
}

fn detachedLabel(repo: Repo) !struct { name: []u8, at: bool } {
    const head = try repo.resolve("HEAD");
    const hex = objects.formatOid(head);
    const logs = repo.read("logs/HEAD") catch |err| switch (err) {
        error.FileNotFound => return .{ .name = try repo.allocator.dupe(u8, hex[0..7]), .at = true },
        else => return err,
    };
    defer repo.allocator.free(logs);
    var candidate: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, logs, '\n');
    while (lines.next()) |line| {
        const message = std.mem.find(u8, line, "\tcheckout: moving from ") orelse continue;
        const text = line[message + 1 ..];
        const to = std.mem.find(u8, text, " to ") orelse continue;
        candidate = text[to + 4 ..];
    }
    if (candidate) |name| {
        if (name.len > 0) {
            const resolved = repo.resolve(name) catch |err| switch (err) {
                error.UnknownRef => null,
                else => return err,
            };
            const at = if (resolved) |oid| std.mem.eql(u8, &oid, &head) else false;
            var is_hex = name.len == 40;
            for (name) |byte| if (!std.ascii.isHex(byte)) {
                is_hex = false;
                break;
            };
            return .{ .name = try repo.allocator.dupe(u8, if (is_hex) name[0..7] else name), .at = at };
        }
    }
    return .{ .name = try repo.allocator.dupe(u8, hex[0..7]), .at = true };
}

fn writePath(out: *std.Io.Writer, path: []const u8) !void {
    var quoted = false;
    for (path) |byte| if (byte <= 32 or byte >= 127 or byte == '\\' or byte == '"') {
        quoted = true;
        break;
    };
    if (!quoted) return out.writeAll(path);
    try out.writeByte('"');
    for (path) |byte| switch (byte) {
        '\\' => try out.writeAll("\\\\"),
        '"' => try out.writeAll("\\\""),
        7 => try out.writeAll("\\a"),
        8 => try out.writeAll("\\b"),
        9 => try out.writeAll("\\t"),
        10 => try out.writeAll("\\n"),
        11 => try out.writeAll("\\v"),
        12 => try out.writeAll("\\f"),
        13 => try out.writeAll("\\r"),
        else => if (byte < 32 or byte >= 127) try out.print("\\{o:0>3}", .{byte}) else try out.writeByte(byte),
    };
    try out.writeByte('"');
}

fn latestTaggedCommit(repo: Repo, out: *std.Io.Writer) !void {
    const refs = try repo.refs();
    defer repo.freeRefs(refs);
    std.mem.sort(Repo.Ref, refs, {}, struct {
        fn less(_: void, a: Repo.Ref, b: Repo.Ref) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);
    var selected: ?objects.Oid = null;
    var timestamp: i64 = std.math.minInt(i64);
    for (refs) |ref| {
        if (!std.mem.startsWith(u8, ref.name, "refs/tags/")) continue;
        const oid = try graph.peel(repo, ref.oid);
        const object = try repo.object(oid);
        defer repo.allocator.free(object.data);
        const commit = try graph.parseCommit(object.data);
        if (selected == null or commit.timestamp > timestamp) {
            selected = oid;
            timestamp = commit.timestamp;
        }
    }
    if (selected) |oid| try out.print("{s}\n", .{objects.formatOid(oid)});
}
