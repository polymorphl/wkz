const std = @import("std");

// wkz — pure-Zig macOS desktop shell library.
//
// Build graph:
//   * module "wkz"      — the library, root src/root.zig
//   * executable "wkz"  — the runnable example, root src/main.zig
//   * build option -Ddev — surfaced to source via the "build_options" module
//   * test step         — runs `test` blocks of both the library and the example
//
// Only third-party dependency: zig-objc (module name "objc"), pinned by hash in
// build.zig.zon. It links Foundation + libobjc and wires the Apple SDK paths for
// its own module; we add AppKit + WebKit (and re-link Foundation/libobjc) on the
// wkz module so consumers inherit them.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dev vs prod is a *compile-time* switch, never a runtime env branch.
    //   -Ddev=true  -> WKWebView loads http://localhost:5173 (Vite dev server)
    //   -Ddev=false -> app:// scheme handler serves @embedFile'd assets (default)
    const dev = b.option(bool, "dev", "Load the Vite dev server instead of embedded assets") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "dev", dev);
    const build_options = options.createModule();

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
            .{ .name = "build_options", .module = build_options },
        },
    });
    // All AppKit/WebKit calls happen on the main thread; these links make the
    // frameworks available to every consumer of the wkz module.
    wkz.linkFramework("AppKit", .{});
    wkz.linkFramework("WebKit", .{});
    wkz.linkFramework("Foundation", .{});
    wkz.linkSystemLibrary("objc", .{});

    // The runnable example.
    const exe = b.addExecutable(.{
        .name = "wkz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wkz", .module = wkz },
                .{ .name = "objc", .module = objc },
                .{ .name = "build_options", .module = build_options },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the example app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // Tests: library + example modules each get their own test executable.
    const lib_tests = b.addTest(.{ .root_module = wkz });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
