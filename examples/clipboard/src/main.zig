//! wkz clipboard example.
//! Demonstrates clipboard.readText and clipboard.writeText bridge handlers.
//! Running: cd examples/clipboard && zig build run

const std = @import("std");
const wkz = @import("wkz");

const UI_HTML: [:0]const u8 = @embedFile("ui.html");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try wkz.app.App.init();
    defer app.deinit();
    try app.installDefaultMenu("wkz Clipboard");

    const window = try wkz.window.Window.init(.{ .width = 640, .height = 440, .title = "wkz Clipboard Demo" });
    const webview = try wkz.webview.WebView.init();
    webview.attach(window);

    var bridge = try wkz.bridge.Bridge.init(allocator, webview.userContentController(), webview.ns_webview);
    try bridge.attach();

    try wkz.clipboard.registerClipboardHandlers(&bridge);

    try webview.loadHTMLString(UI_HTML);
    app.activate();
    app.run();
}
