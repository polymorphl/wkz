//! wkz updater example.
//!
//! Demonstrates the auto-updater API end-to-end: opens a window with an
//! embedded HTML+JS UI, wires the wkz bridge, and registers the updater
//! bridge handlers so the frontend can call `updater.check`, `updater.download`,
//! and `updater.install` via `invoke()`.
//!
//! Running:
//!   cd examples/updater && zig build run
//!
//! The manifest source is resolved relative to the current working directory
//! using `std.process.currentPathAlloc` + `std.fs.path.join` (Zig 0.16 API —
//! `std.fs.cwd()` was removed). `updater.zig` opens it with
//! `openFileAbsolute`, which requires an absolute path.
//! Run from `examples/updater/` so `manifest.json` resolves correctly.
//!
//! The bundled manifest.json has version "0.2.0"; current_version is hardcoded
//! to "0.1.0" so `updater.check` will always find an update. The download URL
//! points to example.com and will fail at runtime — this demo exercises the
//! bridge wiring, not an actual binary download.

const std = @import("std");
const wkz = @import("wkz");

/// Embedded UI — compiled into the binary at build time.
const UI_HTML: [:0]const u8 = @embedFile("ui.html");

pub fn main() !void {
    // std.heap.DebugAllocator is the Zig 0.16 name for GeneralPurposeAllocator
    // (renamed in heap.zig:20). Lives for the entire process lifetime.
    // NOTE: `defer _ = gpa.deinit()` is dead code — app.run() blocks and
    // AppKit's `terminate:` exits the process directly. Written for clarity.
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Resolve manifest.json to an absolute path. updater.zig calls
    // std.fs.openFileAbsolute which requires an absolute path.
    //
    // Zig 0.16: std.fs.cwd() was removed. Use std.process.currentPathAlloc
    // (std/process.zig:82, signature: fn(io, allocator) ![:0]u8) to get the
    // cwd, then std.fs.path.join (std/fs/path.zig:135) to append the filename.
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const manifest_path = try std.fs.path.join(allocator, &.{ cwd, "manifest.json" });
    defer allocator.free(manifest_path);

    // NSApplication must exist before any window is created.
    const app = try wkz.app.App.init();

    // Centered, titled window. No deinit — see lifetime note below.
    const window = try wkz.window.Window.init(700, 480, "wkz Updater Demo");

    // Plain WKWebView (no app:// scheme handler; HTML is loaded inline).
    const webview = try wkz.webview.WebView.init();
    webview.attach(window);

    // Bridge.init takes the WKUserContentController and the raw ns_webview
    // objc.Object (for evaluateJavaScript replies). Returns by value; we take
    // a stable address with `var` before calling attach(*Bridge).
    var bridge = try wkz.bridge.Bridge.init(
        allocator,
        webview.userContentController(),
        webview.ns_webview,
    );
    // attach() writes the Bridge pointer into the ObjC message handler ivar
    // so the IMP can recover it on every incoming message.
    try bridge.attach();

    // Updater.init returns by value (not an error union).
    var updater = wkz.updater.Updater.init(allocator, .{
        .manifest_source = .{ .file = manifest_path },
        .current_version = "0.1.0",
        // null = signature verification disabled for this demo.
        .public_key = null,
    });

    // Register the three updater bridge handlers: updater.check,
    // updater.download, updater.install. Must be called AFTER bridge.attach().
    // Also sets bridge.context = &updater so the handlers can recover the
    // Updater pointer via @ptrCast.
    try wkz.updater.registerBridgeHandlers(&updater, &bridge);

    // Load content AFTER the bridge is fully wired. WebKit only applies
    // addScriptMessageHandler to content loaded after the call.
    try webview.loadHTMLString(UI_HTML);

    // Foreground the app and enter the AppKit run loop. run() blocks until
    // AppKit's `terminate:` exits the process directly — it never returns.
    // Therefore no defer deinit() calls are installed for window/webview/bridge/
    // updater: they would be dead code, and the OS reclaims memory on exit.
    app.activate();
    app.run();
}
