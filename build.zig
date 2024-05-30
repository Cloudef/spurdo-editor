const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ztd = b.dependency("ztd", .{});

    const aio = b.dependency("aio", .{
        .target = target,
        .optimize = optimize,
    });

    const lsp = b.dependency("lsp-codegen", .{
        .target = target,
        .optimize = optimize,
        .@"meta-model" = @as([]const u8, "lsp.json"),
    });

    const datetime = b.dependency("datetime", .{});

    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const zg = vaxis.builder.dependency("zg", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "master",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);
    exe.root_module.addImport("ztd", ztd.module("ztd"));
    exe.root_module.addImport("aio", aio.module("aio"));
    exe.root_module.addImport("coro", aio.module("coro"));
    exe.root_module.addImport("vaxis", vaxis.module("vaxis"));
    exe.root_module.addImport("grapheme", zg.module("grapheme"));
    exe.root_module.addImport("DisplayWidth", zg.module("DisplayWidth"));
    exe.root_module.addImport("lsp-generated", lsp.module("lsp"));
    exe.root_module.addImport("datetime", datetime.module("datetime"));

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
