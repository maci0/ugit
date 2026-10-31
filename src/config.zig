// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");

/// Borrows a scalar value from config; caller retains the config bytes.
pub fn value(config: []const u8, section: []const u8, key: []const u8) ?[]const u8 {
    var active = false;
    var result: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, config, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            active = std.mem.endsWith(u8, line, "]") and std.mem.eql(u8, line[1 .. line.len - 1], section);
            continue;
        }
        if (!active) continue;
        const equal = std.mem.findScalar(u8, line, '=') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..equal], " \t"), key)) {
            result = std.mem.trim(u8, line[equal + 1 ..], " \t");
        }
    }
    return result;
}

test "config values preserve subsection names and select last value" {
    try std.testing.expectEqualStrings("https://example/repo.git", value("[remote \"origin\"]\n url = https://example/repo.git\n", "remote \"origin\"", "url") orelse return error.MissingValue);
    try std.testing.expectEqualStrings("second", value("[core]\n x = first\n x = second\n", "core", "x") orelse return error.MissingValue);
    try std.testing.expect(value("[other]\n x = no\n", "core", "x") == null);
}
