//! wkz events example.
//! Demonstrates window focus/blur events pushed from Zig to JS via
//! NSNotificationCenter. Click another app to blur the window; click back to
//! focus it. Each transition is logged in the web UI.
//!
//! Running:
//!   cd examples/events && zig build run

const std = @import("std");
const wkz = @import("wkz");

const UI_HTML: [:0]const u8 = @embedFile("ui.html");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try wkz.app.App.init();
    defer app.deinit();
    try app.installDefaultMenu("wkz Events");

    const window = try wkz.window.Window.init(.{
        .width = 640,
        .height = 400,
        .title = "wkz Window Events",
    });

    const webview = try wkz.webview.WebView.init();
    webview.attach(window);

    var bridge = try wkz.bridge.Bridge.init(
        allocator,
        webview.userContentController(),
        webview.ns_webview,
    );
    try bridge.attach();

    const we = try wkz.events.WindowEvents.init(allocator, window, &bridge);
    defer we.deinit();

    try webview.loadHTMLString(UI_HTML);

    app.activate();
    app.run();
}
