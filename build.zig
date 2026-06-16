const std = @import("std");

// wkz — pure-Zig macOS desktop shell library.
//
// Build graph:
//   * module "wkz"  — the library, root src/root.zig
//   * test step     — runs `test` blocks of the library and gen_assets tool
//
// Only third-party dependency: zig-objc (module name "objc"), pinned by hash in
// build.zig.zon. It links Foundation + libobjc and wires the Apple SDK paths for
// its own module; we add AppKit + WebKit (and re-link Foundation/libobjc) on the
// wkz module so consumers inherit them.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zig-objc: the Objective-C runtime bindings.
    const objc = b.dependency("zig_objc", .{
        .target = target,
        .optimize = optimize,
    }).module("objc");

    // The library module, exposed to consumers as `@import("wkz")`.
    const wkz = b.addModule("wkz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "objc", .module = objc },
        },
    });
    // All AppKit/WebKit calls happen on the main thread; these links make the
    // frameworks available to every consumer of the wkz module.
    wkz.linkFramework("AppKit", .{});
    wkz.linkFramework("WebKit", .{});
    wkz.linkFramework("Foundation", .{});
    wkz.linkFramework("UserNotifications", .{});
    wkz.linkSystemLibrary("objc", .{});

    // Tests for tools/gen_assets.zig (pure-Zig, no ObjC, host target).
    const gen_assets_test_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_assets.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = .Debug,
    });
    const gen_assets_tests = b.addTest(.{ .root_module = gen_assets_test_mod });
    const run_gen_assets_tests = b.addRunArtifact(gen_assets_tests);

    const lib_tests = b.addTest(.{ .root_module = wkz });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_gen_assets_tests.step);

    // Docs step: `zig build docs` → zig-out/docs/index.html
    const lib = b.addLibrary(.{
        .name = "wkz",
        .root_module = wkz,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API documentation");
    docs_step.dependOn(&install_docs.step);
}
