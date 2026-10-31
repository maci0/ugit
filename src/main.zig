// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const invocation = cli.parse(argv[1..]) catch |err| {
        std.debug.print("ugit: {s}\n", .{@errorName(err)});
        std.process.exit(128);
    };
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    const code = @import("commands.zig").run(init.gpa, init.io, invocation, &writer.interface) catch |err| {
        switch (err) {
            error.InvalidObject, error.InvalidPack, error.InvalidIndex, error.InvalidPackChecksum, error.InvalidIndexChecksum, error.InvalidTree, error.InvalidCommit => std.debug.print("fatal: corrupt repository ({s})\n", .{@errorName(err)}),
            else => std.debug.print("fatal: {s}\n", .{@errorName(err)}),
        }
        std.process.exit(if (err == error.ConfigNotFound) 1 else 128);
    };
    try writer.interface.flush();
    if (code != 0) std.process.exit(code);
}

test {
    _ = @import("cli.zig");
    _ = @import("objects.zig");
    _ = @import("Repo.zig");
    _ = @import("commands.zig");
}
