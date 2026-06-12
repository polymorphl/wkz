//! wkz fs example.
//!
//! Demonstrates the wkz.fs bridge module: open a native file picker (NSOpenPanel),
//! read files as text or binary (base64), and write text files — all wired through
//! the JS<->Zig bridge.
//!
//! Running:
//!   cd examples/fs && zig build run

const std = @import("std");
const wkz = @import("wkz");

const UI_HTML: [:0]const u8 = @embedFile("ui.html");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const app = try wkz.app.App.init();
    const window = try wkz.window.Window.init(720, 540, "wkz FS Demo");
    const webview = try wkz.webview.WebView.init();
    webview.attach(window);

    var bridge = try wkz.bridge.Bridge.init(
        allocator,
        webview.userContentController(),
        webview.ns_webview,
    );
    try bridge.attach();

    var fs = wkz.fs.Fs.init(allocator);
    try fs.registerBridgeHandlers(&bridge);

    try webview.loadHTMLString(UI_HTML);

    app.activate();
    app.run();
}
