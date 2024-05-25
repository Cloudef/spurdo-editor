const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const root_source_file = b.path("src/zignet.zig");

    _ = b.addModule("zignet", .{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
    });
    const tests_run = b.addRunArtifact(tests);
    b.installArtifact(tests);
    const tests_step = b.step("test", "Run tests");
    tests_step.dependOn(&tests_run.step);
}
