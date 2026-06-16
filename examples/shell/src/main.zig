//! wkz shell example.
//! Demonstrates shell.open — opening a URL in the default browser via
//! NSWorkspace openURL: from a JS bridge call.
//!
//! Running:
//!   cd examples/shell && zig build run

const std = @import("std");
const wkz = @import("wkz");

const UI_HTML: [:0]const u8 = @embedFile("ui.html");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try wkz.app.App.init();
    defer app.deinit();
    try app.installDefaultMenu("wkz Shell");

    const window = try wkz.window.Window.init(.{
        .width = 560,
        .height = 400,
        .title = "wkz Shell Demo",
    });

    const webview = try wkz.webview.WebView.init();
    webview.attach(window);

    var bridge = try wkz.bridge.Bridge.init(
        allocator,
        webview.userContentController(),
        webview.ns_webview,
    );
    try bridge.attach();

    try wkz.shell.registerHandlers(&bridge);

    try webview.loadHTMLString(UI_HTML);

    app.activate();
    // run() blocks until terminate: exits the process (e.g. Cmd+Q).
    // deinit calls are intentionally omitted: the run loop never returns and
    // terminate: exits the process, so post-run cleanup is unreachable dead code.
    app.run();
}
