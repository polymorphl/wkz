const std = @import("std");

// Asset pipeline (prod, -Ddev=false):
//   1. npm run build in frontend/ → frontend/dist/
//   2. gen_assets (../../tools/gen_assets.zig) walks dist/ and emits dist_assets.zig
//      with one @embedFile entry per asset, keyed by relative path + MIME type.
//   3. dist_assets module is added to the exe so main.zig can @import("dist_assets").
//
// Dev mode (-Ddev=true): a stub dist_assets module (empty AssetMap) is added
// instead, so the @import("dist_assets") in main.zig always compiles.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dev = b.option(bool, "dev", "Load the Vite dev server instead of embedded assets") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "dev", dev);
    const build_options = options.createModule();

    const wkz_dep = b.dependency("wkz", .{ .target = target, .optimize = optimize });
    const wkz = wkz_dep.module("wkz");

    const exe = b.addExecutable(.{
        .name = "basic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wkz", .module = wkz },
                .{ .name = "build_options", .module = build_options },
            },
        }),
    });

    if (dev) {
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
        const npm_build = b.addSystemCommand(&.{ "npm", "run", "build" });
        npm_build.setCwd(b.path("frontend"));

        const gen_assets_mod = b.createModule(.{
            .root_source_file = b.path("../../tools/gen_assets.zig"),
            .target = b.resolveTargetQuery(.{}),
            .optimize = .Debug,
        });
        const gen_assets_exe = b.addExecutable(.{
            .name = "gen_assets",
            .root_module = gen_assets_mod,
        });

        const gen_run = b.addRunArtifact(gen_assets_exe);
        gen_run.has_side_effects = true;
        gen_run.step.dependOn(&npm_build.step);
        gen_run.addArg(b.pathFromRoot("frontend/dist"));
        const dist_assets_dir = gen_run.addOutputDirectoryArg("dist_assets_dir");

        const dist_assets_mod = b.createModule(.{
            .root_source_file = dist_assets_dir.path(b, "dist_assets.zig"),
            .imports = &.{.{ .name = "wkz", .module = wkz }},
        });
        exe.root_module.addImport("dist_assets", dist_assets_mod);
    }

    b.installArtifact(exe);

    const plist_content =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>CFBundleName</key>
        \\    <string>basic</string>
        \\    <key>CFBundleIdentifier</key>
        \\    <string>com.wkz.example.basic</string>
        \\    <key>CFBundleVersion</key>
        \\    <string>0.1.0</string>
        \\    <key>CFBundleShortVersionString</key>
        \\    <string>0.1.0</string>
        \\    <key>CFBundleExecutable</key>
        \\    <string>basic</string>
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

    const install_exe = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "basic.app/Contents/MacOS" } },
    });
    b.getInstallStep().dependOn(&install_exe.step);

    const install_plist = b.addInstallFile(plist_lazy_path, "basic.app/Contents/Info.plist");
    b.getInstallStep().dependOn(&install_plist.step);

    const codesign = b.addSystemCommand(&.{ "codesign", "--force", "--deep", "--sign", "-" });
    codesign.addArg(b.getInstallPath(.prefix, "basic.app"));
    codesign.step.dependOn(&install_exe.step);
    codesign.step.dependOn(&install_plist.step);
    b.getInstallStep().dependOn(&codesign.step);

    const run_step = b.step("run", "Run the basic example");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
}
