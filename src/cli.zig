// SPDX-License-Identifier: GPL-3.0-only
//! Closed command grammar for the Moonraker/Phobos Git callers.
const std = @import("std");

pub const max_args: usize = 32;
pub const max_arg_bytes: usize = 4096;
pub const Command = enum {
    status,
    branch,
    config,
    remote,
    fetch,
    rev_parse,
    describe,
    rev_list,
    merge_base,
    log,
    for_each_ref,
    pull,
    checkout,
    reset,
    clone,
    cat_file,
    fsck,
    clean,
};

pub const Invocation = struct {
    directory: []const u8,
    command: Command,
    args: []const []const u8,
};

pub const ParseError = error{ InvalidArguments, UnsupportedCommand };

/// The result borrows argv; no shell expansion or allocation is performed.
pub fn parse(argv: []const []const u8) ParseError!Invocation {
    if (argv.len == 0 or argv.len > max_args) return error.InvalidArguments;
    for (argv) |arg| {
        if (arg.len == 0 or arg.len > max_arg_bytes) return error.InvalidArguments;
        if (std.mem.findScalar(u8, arg, 0) != null) return error.InvalidArguments;
    }
    var index: usize = 0;
    var directory: []const u8 = ".";
    if (eq(argv[0], "-C")) {
        if (argv.len < 3) return error.InvalidArguments;
        directory = argv[1];
        index = 2;
    }
    const name = argv[index];
    const command = inline for (@typeInfo(Command).@"enum".field_names) |field| {
        const spelling = comptime spellingOf(field);
        if (eq(name, &spelling)) break @field(Command, field);
    } else return error.UnsupportedCommand;
    const args = argv[index + 1 ..];
    try validate(command, args);
    return .{ .directory = directory, .command = command, .args = args };
}

fn spellingOf(comptime name: []const u8) [name.len]u8 {
    var result: [name.len]u8 = @splat(0);
    for (name, 0..) |byte, i| result[i] = if (byte == '_') '-' else byte;
    return result;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isOneOf(value: []const u8, values: []const []const u8) bool {
    for (values) |candidate| if (eq(value, candidate)) return true;
    return false;
}

fn operands(args: []const []const u8, flags: []const []const u8, prefixes: []const []const u8) ParseError!usize {
    var count: usize = 0;
    for (args) |arg| {
        if (arg[0] != '-') {
            count += 1;
            continue;
        }
        if (isOneOf(arg, flags)) continue;
        var allowed = false;
        for (prefixes) |prefix| {
            if (std.mem.startsWith(u8, arg, prefix) and arg.len > prefix.len) allowed = true;
        }
        if (!allowed) return error.InvalidArguments;
    }
    return count;
}

fn validate(command: Command, args: []const []const u8) ParseError!void {
    switch (command) {
        .status => {
            if (try operands(args, &.{ "--porcelain", "-b", "--ignored" }, &.{}) != 0) return error.InvalidArguments;
            if (!isOneOf("--porcelain", args)) return error.InvalidArguments;
        },
        .branch => {
            if (args.len == 1 and eq(args[0], "--no-color")) return;
            if (args.len != 2 or !eq(args[0], "--list") or !eq(args[1], "--no-color")) return error.InvalidArguments;
        },
        .rev_parse => {
            if (args.len == 1 and args[0][0] != '-') return;
            if (args.len != 2 or !eq(args[0], "--abbrev-ref") or !eq(args[1], "HEAD")) return error.InvalidArguments;
        },
        .fetch => {
            if (try operands(args, &.{ "--all", "--prune", "--progress", "-p" }, &.{}) > 1) return error.InvalidArguments;
            if (args.len == 0) return error.InvalidArguments;
        },
        .describe => {
            if (try operands(args, &.{ "--tags", "--always", "--long", "--dirty" }, &.{"--abbrev="}) > 1) return error.InvalidArguments;
        },
        .rev_list => {
            if (args.len == 2 and eq(args[0], "--tags") and eq(args[1], "--max-count=1")) return;
            if (try operands(args, &.{"--count"}, &.{}) != 1 or !isOneOf("--count", args)) return error.InvalidArguments;
        },
        .merge_base => {
            if (args.len != 3 or !eq(args[0], "--is-ancestor")) return error.InvalidArguments;
        },
        .reset => {
            if (args.len != 2 or !eq(args[0], "--hard") or args[1][0] == '-') return error.InvalidArguments;
        },
        .checkout => {
            if (args.len == 1 and args[0][0] != '-') return;
            if (args.len == 2 and eq(args[0], "-q") and args[1][0] != '-') return;
            if (args.len != 3 or !eq(args[0], "-q") or !eq(args[1], "--") or !eq(args[2], ".")) return error.InvalidArguments;
        },
        .clean => {
            if (args.len == 1 and eq(args[0], "-fd")) return;
            if (args.len != 2 or !eq(args[0], "-d") or !eq(args[1], "-f")) return error.InvalidArguments;
        },
        .fsck => {
            if (args.len != 1 or !eq(args[0], "--full")) return error.InvalidArguments;
        },
        .cat_file => {
            if (args.len != 2 or !eq(args[0], "-e") or !std.mem.endsWith(u8, args[1], "^{commit}")) return error.InvalidArguments;
        },
        .remote => {
            if (args.len == 0) return;
            if (args.len == 2 and eq(args[0], "get-url") and args[1][0] != '-') return;
            if (args.len != 3 or !eq(args[0], "set-url") or args[1][0] == '-') return error.InvalidArguments;
        },
        .pull => {
            const n = try operands(args, &.{ "--progress", "--rebase" }, &.{});
            if ((n != 0 and n != 2) or !isOneOf("--progress", args)) return error.InvalidArguments;
        },
        .clone => {
            if (args.len != 5 or !eq(args[0], "--branch") or !eq(args[2], "--filter=blob:none")) return error.InvalidArguments;
        },
        .log => {
            if (try operands(args, &.{}, &.{ "--format=", "--max-count=" }) != 1) return error.InvalidArguments;
        },
        .for_each_ref => {
            if (try operands(args, &.{}, &.{ "--count=", "--sort=", "--contains=", "--merged=", "--format=" }) != 1) return error.InvalidArguments;
        },
        .config => {
            if (args.len != 2 or !eq(args[0], "--get") or args[1][0] == '-') return error.InvalidArguments;
        },
    }
}

test "accept caller commands and reject unrelated Git commands" {
    const parsed = try parse(&.{ "-C", "/repo", "fetch", "origin", "--prune", "--progress" });
    try std.testing.expectEqual(Command.fetch, parsed.command);
    try std.testing.expectEqualStrings("/repo", parsed.directory);
    try std.testing.expectError(error.UnsupportedCommand, parse(&.{ "push", "origin" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "reset", "--soft", "HEAD" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "-C", "/repo" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "status", "--porcelain", "a\x00b" }));
}

test "all command variants are validated" {
    const examples: []const []const []const u8 = &.{
        &.{ "status", "--porcelain", "-b" },
        &.{ "branch", "--list", "--no-color" },
        &.{ "config", "--get", "branch.main.remote" },
        &.{ "remote", "get-url", "origin" },
        &.{ "fetch", "--all", "-p" },
        &.{ "rev-parse", "--abbrev-ref", "HEAD" },
        &.{ "describe", "--tags", "--always", "--long", "--dirty", "--abbrev=8" },
        &.{ "rev-list", "HEAD..origin/main", "--count" },
        &.{ "merge-base", "--is-ancestor", "HEAD", "origin/main" },
        &.{ "log", "HEAD..origin/main", "--format=%H", "--max-count=100" },
        &.{ "for-each-ref", "--count=100", "--sort=-creatordate", "--contains=HEAD", "--merged=origin/main", "--format=%(refname)", "refs/tags" },
        &.{ "pull", "--progress" },
        &.{ "checkout", "-q", "--", "." },
        &.{ "reset", "--hard", "HEAD" },
        &.{ "clone", "--branch", "main", "--filter=blob:none", "https://example.invalid/repo.git", "backup" },
        &.{ "cat-file", "-e", "HEAD^{commit}" },
        &.{ "fsck", "--full" },
        &.{ "clean", "-fd" },
    };
    for (examples) |args| _ = try parse(args);
}
