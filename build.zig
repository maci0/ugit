// SPDX-License-Identifier: GPL-3.0-only
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .abi = .musl } });
    const optimize = b.standardOptimizeOption(.{});
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });
    b.installArtifact(b.addExecutable(.{ .name = "ugit", .root_module = module }));
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    }) });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
