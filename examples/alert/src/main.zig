//! wkz alert example.
//!
//! Demonstrates the wkz.alert bridge module: three NSAlert scenarios wired
//! through the JS<->Zig bridge — simple, confirmation (critical), informational.
//!
//! Running:
//!   cd examples/alert && zig build run

const std = @import("std");
const wkz = @import("wkz");

const UI_HTML: [:0]const u8 = @embedFile("ui.html");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const app = try wkz.app.App.init();
    defer app.deinit();
    const window = try wkz.window.Window.init(.{
        .width = 640,
        .height = 480,
        .title = "wkz Alert Demo",
    });
    const webview = try wkz.webview.WebView.init();
    webview.attach(window);

    var bridge = try wkz.bridge.Bridge.init(
        allocator,
        webview.userContentController(),
        webview.ns_webview,
    );
    try bridge.attach();

    try wkz.alert.registerAlertHandler(&bridge);

    try webview.loadHTMLString(UI_HTML);

    app.activate();
    app.run();
}
