//! wkz statusitem example.
//!
//! Demonstrates the wkz.statusitem bridge module: create and update a native
//! macOS menu-bar status item (title and/or SF Symbol icon) and receive click
//! events back in JS via window.__wkz_event.
//!
//! Running:
//!   cd examples/statusitem && zig build run

const std = @import("std");
const wkz = @import("wkz");

const UI_HTML: [:0]const u8 = @embedFile("ui.html");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try wkz.app.App.init();
    defer app.deinit();
    try app.installDefaultMenu("wkz StatusItem Demo");
    const window = try wkz.window.Window.init(.{
        .width = 560,
        .height = 420,
        .title = "wkz StatusItem Demo",
    });
    const webview = try wkz.webview.WebView.init();
    webview.attach(window);

    var bridge = try wkz.bridge.Bridge.init(
        allocator,
        webview.userContentController(),
        webview.ns_webview,
    );
    try bridge.attach();

    // StatusItem uses bridge.context — cannot share bridge with Fs or Updater.
    var status_item = wkz.statusitem.StatusItem.init(allocator, &bridge);
    defer status_item.deinit();
    try status_item.registerBridgeHandlers(&bridge);

    try webview.loadHTMLString(UI_HTML);

    app.activate();
    app.run();
}
