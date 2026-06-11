const std = @import("std");

// wkz — pure-Zig macOS desktop shell library.
//
// Build graph:
//   * module "wkz"        — the library, root src/root.zig
//   * executable "wkz"    — the runnable example, root src/main.zig
//   * build option -Ddev  — surfaced to source via the "build_options" module
//   * test step           — runs `test` blocks of both the library and the example
//
// Asset pipeline (prod, -Ddev=false):
//   1. npm run build in frontend/ → frontend/dist/
//   2. gen_assets (tools/gen_assets.zig) walks dist/ and emits src/dist_assets.zig
//      with one @embedFile entry per asset, keyed by relative path + MIME type.
//   3. dist_assets module is added to the exe so main.zig can @import("dist_assets").
//
// Dev mode (-Ddev=true): a stub dist_assets module (empty AssetMap) is added
// instead, so the @import("dist_assets") in main.zig always compiles.
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

    // Asset pipeline: always add a "dist_assets" module to the exe so that
    // `@import("dist_assets")` in main.zig compiles in both dev and prod.
    //
    // Dev: stub module with an empty AssetMap — npm build is never run.
    // Prod: npm run build → gen_assets → generated Zig source with @embedFile entries.
    if (dev) {
        // Stub: empty AssetMap, no npm build, no @embedFile.
        // b.addWriteFiles().add: Build/Step/WriteFile.zig:104
        const stub = b.addWriteFiles();
        const stub_file = stub.add("dist_assets.zig",
            \\const wkz = @import("wkz");
            \\pub const asset_map = wkz.scheme.AssetMap{ .entries = &.{} };
            \\
        );
        const dist_assets_mod = b.createModule(.{
            .root_source_file = stub_file,
            .imports = &.{.{ .name = "wkz", .module = wkz }},
        });
        exe.root_module.addImport("dist_assets", dist_assets_mod);
    } else {
        // Step 1: run `npm run build` in frontend/ to produce frontend/dist/.
        // addSystemCommand + setCwd: Build/Step/Run.zig:535
        const npm_build = b.addSystemCommand(&.{ "npm", "run", "build" });
        npm_build.setCwd(b.path("frontend"));

        // Step 2: build the gen_assets code-generator executable.
        // It runs on the host (build machine), not the target.
        // addExecutable: Build.zig:787 — takes root_module: *Module
        // b.graph.host: Build.zig:126 — ResolvedTarget for the host
        const gen_assets_mod = b.createModule(.{
            .root_source_file = b.path("tools/gen_assets.zig"),
            .target = b.resolveTargetQuery(.{}), // native host
            .optimize = .Debug,
        });
        const gen_assets_exe = b.addExecutable(.{
            .name = "gen_assets",
            .root_module = gen_assets_mod,
        });

        // Step 3: run gen_assets to produce the generated Zig source.
        // gen_run.step depends on npm_build so Vite runs first.
        // addRunArtifact: Build.zig:934
        // addArg: Build/Step/Run.zig:518
        // addOutputDirectoryArg: Build/Step/Run.zig:419 — returns LazyPath (directory)
        const gen_run = b.addRunArtifact(gen_assets_exe);
        // has_side_effects = true: dist/ content can change without changing
        // the argv, so we must always re-run gen_assets to pick up fresh Vite
        // output. The exe compilation is still cached when dist/ is unchanged.
        gen_run.has_side_effects = true;
        gen_run.step.dependOn(&npm_build.step);
        // Pass the absolute dist_dir path.
        // b.pathFromRoot: Build.zig:1770 — returns []u8 (absolute)
        gen_run.addArg(b.pathFromRoot("frontend/dist"));
        // The output directory basename. The build system manages the cache path.
        // gen_assets copies assets + writes dist_assets.zig into this directory.
        const dist_assets_dir = gen_run.addOutputDirectoryArg("dist_assets_dir");

        // Step 4: create the dist_assets module from the generated file and
        // wire it into the exe. It imports wkz so the AssetMap type resolves.
        // LazyPath.path: Build.zig:2432 — path(lazy_path, b, sub_path) LazyPath
        const dist_assets_mod = b.createModule(.{
            .root_source_file = dist_assets_dir.path(b, "dist_assets.zig"),
            .imports = &.{.{ .name = "wkz", .module = wkz }},
        });
        exe.root_module.addImport("dist_assets", dist_assets_mod);
    }

    b.installArtifact(exe);

    // .app bundle (prod + dev both get the bundle layout).
    // `b.installArtifact(exe)` above installs to `zig-out/bin/wkz`, which is
    // what `zig build run` resolves via addRunArtifact. The `install_exe` below
    // installs the same artifact a second time into the bundle. Both outputs are
    // intentional and always identical — the Zig build system compiles the
    // artifact once and copies it to both destinations.
    //
    // Verified APIs (Build.zig / Build/Step/InstallArtifact.zig, Zig 0.16.0):
    //   addInstallArtifact(b, artifact, Options) *Step.InstallArtifact  — line 1666
    //     Options.dest_dir: Dir = .default  — InstallArtifact.zig:40
    //     Dir = union(enum){ disabled, default, override: InstallDir }  — line 52
    //     InstallDir = union(enum){ prefix, lib, bin, header, custom: []const u8 }
    //                                                              — Build.zig:2667
    //   addInstallFile(b, source: LazyPath, dest_rel_path) *Step.InstallFile  — line 1698
    //     (installs relative to install prefix, i.e. zig-out/)
    //   addWriteFiles().add(sub_path, bytes) LazyPath  — WriteFile.zig:104

    // Generate Info.plist content.
    const plist_content =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>CFBundleName</key>
        \\    <string>wkz</string>
        \\    <key>CFBundleIdentifier</key>
        \\    <string>com.wkz.example</string>
        \\    <key>CFBundleVersion</key>
        \\    <string>0.1.0</string>
        \\    <key>CFBundleShortVersionString</key>
        \\    <string>0.1.0</string>
        \\    <key>CFBundleExecutable</key>
        \\    <string>wkz</string>
        \\    <key>CFBundlePackageType</key>
        \\    <string>APPL</string>
        \\    <key>NSAllowsLocalNetworking</key>
        \\    <true/>
        \\    <key>NSHighResolutionCapable</key>
        \\    <true/>
        \\</dict>
        \\</plist>
        \\
    ;
    const wf = b.addWriteFiles();
    const plist_lazy_path = wf.add("Info.plist", plist_content);

    // Install executable into wkz.app/Contents/MacOS/wkz (relative to zig-out/).
    const install_exe = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "wkz.app/Contents/MacOS" } },
    });
    b.getInstallStep().dependOn(&install_exe.step);

    // Install Info.plist into wkz.app/Contents/Info.plist (relative to zig-out/).
    // Sibling of MacOS/ — required by the .app bundle spec; CFBundleExecutable
    // must match the binary name at Contents/MacOS/.
    const install_plist = b.addInstallFile(plist_lazy_path, "wkz.app/Contents/Info.plist");
    b.getInstallStep().dependOn(&install_plist.step);

    // Ad-hoc codesign so the .app bundle can be launched from Finder without
    // the "unidentified developer" Gatekeeper blocker on the developer's own
    // machine.  Identity "-" means ad-hoc (no Apple Developer account required).
    //
    // Verified APIs (Zig 0.16.0):
    //   addSystemCommand(b: *Build, argv: []const []const u8) *Step.Run  — Build.zig:927
    //   addArg(run: *Run, arg: []const u8) void                          — Run.zig:518
    //   getInstallPath(b: *Build, dir: InstallDir, rel: []const u8) []const u8 — Build.zig:1928
    const codesign = b.addSystemCommand(&.{ "codesign", "--force", "--deep", "--sign", "-" });
    codesign.addArg(b.getInstallPath(.prefix, "wkz.app"));
    codesign.step.dependOn(&install_exe.step);
    codesign.step.dependOn(&install_plist.step);
    b.getInstallStep().dependOn(&codesign.step);

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

    // Tests for tools/gen_assets.zig (pure-Zig, no ObjC, host target).
    // gen_assets_mod is already defined above in the prod branch; rebuild a
    // fresh module here so the test step is independent of the -Ddev flag.
    const gen_assets_test_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_assets.zig"),
        .target = b.resolveTargetQuery(.{}), // native host
        .optimize = .Debug,
    });
    const gen_assets_tests = b.addTest(.{ .root_module = gen_assets_test_mod });
    const run_gen_assets_tests = b.addRunArtifact(gen_assets_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_gen_assets_tests.step);
}
