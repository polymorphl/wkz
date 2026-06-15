const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wkz_dep = b.dependency("wkz", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "clipboard_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("wkz", wkz_dep.module("wkz"));

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the clipboard example");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
}
