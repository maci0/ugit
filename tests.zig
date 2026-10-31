// SPDX-License-Identifier: GPL-3.0-only
test {
    _ = @import("build.zig");
    _ = @import("src/main.zig");
    _ = @import("src/cli.zig");
    _ = @import("src/config.zig");
    _ = @import("src/objects.zig");
    _ = @import("src/Repo.zig");
    _ = @import("src/pack.zig");
    _ = @import("src/graph.zig");
    _ = @import("src/worktree.zig");
    _ = @import("src/ignore.zig");
    _ = @import("src/transport.zig");
    _ = @import("src/mutate.zig");
    _ = @import("src/display.zig");
    _ = @import("src/commands.zig");
}
