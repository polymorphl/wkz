const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wkz_dep = b.dependency("wkz", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "notifications_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("wkz", wkz_dep.module("wkz"));

    // UNUserNotificationCenter requires the process to be launched via
    // Launch Services (as a proper .app bundle). Build the bundle and use
    // `open -W` in the run step so macOS sets up bundleProxyForCurrentProcess.
    const plist_content =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>CFBundleIdentifier</key>
        \\    <string>com.wkz.notifications</string>
        \\    <key>CFBundleName</key>
        \\    <string>wkz Notifications</string>
        \\    <key>CFBundleExecutable</key>
        \\    <string>notifications_example</string>
        \\    <key>CFBundleVersion</key>
        \\    <string>1</string>
        \\    <key>NSHighResolutionCapable</key>
        \\    <true/>
        \\</dict>
        \\</plist>
        \\
    ;
    const wf = b.addWriteFiles();
    const plist_lazy_path = wf.add("Info.plist", plist_content);

    const install_exe = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = "notifications.app/Contents/MacOS" } },
    });
    b.getInstallStep().dependOn(&install_exe.step);

    const install_plist = b.addInstallFile(plist_lazy_path, "notifications.app/Contents/Info.plist");
    b.getInstallStep().dependOn(&install_plist.step);

    const codesign = b.addSystemCommand(&.{ "codesign", "--force", "--deep", "--sign", "-" });
    codesign.addArg(b.getInstallPath(.prefix, "notifications.app"));
    codesign.step.dependOn(&install_exe.step);
    codesign.step.dependOn(&install_plist.step);
    b.getInstallStep().dependOn(&codesign.step);

    // Use `open -W` to launch via Launch Services — required for UNUserNotificationCenter.
    const run_step = b.step("run", "Run the notifications example");
    const open_cmd = b.addSystemCommand(&.{ "open", "-W" });
    open_cmd.addArg(b.getInstallPath(.prefix, "notifications.app"));
    open_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&open_cmd.step);
}
