//! wkz dragdrop example.
//! Demonstrates file drag-and-drop: drop files onto the window to see their
//! paths listed in the web UI.
//!
//! Running:
//!   cd examples/dragdrop && zig build run

const std = @import("std");
const wkz = @import("wkz");

const UI_HTML: [:0]const u8 = @embedFile("ui.html");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try wkz.app.App.init();
    defer app.deinit();
    try app.installDefaultMenu("wkz Drag & Drop");

    const win = try wkz.window.Window.init(.{
        .width = 720,
        .height = 500,
        .title = "wkz Drag & Drop",
    });

    const webview = try wkz.webview.WebView.init();
    webview.attach(win);

    var bridge = try wkz.bridge.Bridge.init(
        allocator,
        webview.userContentController(),
        webview.ns_webview,
    );
    try bridge.attach();

    // DragDrop: wire file drops to bridge events.
    // DragDrop.init places a transparent overlay above the WKWebView that
    // accepts file drags and emits `dragdrop.filesDropped` events.
    const dd = try wkz.dragdrop.DragDrop.init(allocator, win, &bridge);
    defer dd.deinit();

    try webview.loadHTMLString(UI_HTML);

    app.activate();
    app.run();
}
