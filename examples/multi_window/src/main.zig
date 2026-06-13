//! Multi-window example for wkz.
//!
//! Opens two independent windows, each with a WKWebView. A close callback logs
//! which window closed. App quits automatically when the last window closes.
//! Main thread only.
//!
//! NOTE: `defer *.deinit()` calls below are intentionally present for ARC
//! correctness documentation and early-return leak detection. In practice
//! `app.run()` blocks and `terminate:` exits the process directly, so these
//! defers are dead code on the normal path — the OS reclaims memory on exit.

const std = @import("std");
const wkz = @import("wkz");

/// Close handler context: the window label. Must not move after being passed to
/// `setCloseHandler` — stack-pinned in `main` for the process lifetime.
const WinCtx = struct {
    label: [:0]const u8,
};

/// Called by WkzWindowDelegate when a window is about to close.
fn onClose(ptr: *anyopaque) void {
    const ctx: *WinCtx = @ptrCast(@alignCast(ptr));
    std.log.info("{s} closed", .{ctx.label});
}

pub fn main() !void {
    var app = try wkz.app.App.init();
    try app.setQuitOnLastWindowClosed(true);
    defer app.deinit();

    // Cascade layout: position windows so they don't overlap.
    // cascadeFrom returns the suggested top-left for the next window.
    const cascade_start = wkz.window.CGPoint{ .x = 100, .y = 700 };

    // Window A — ctx_a must not move after setCloseHandler (stack-pinned here).
    var window_a = try wkz.window.Window.init(800, 600, "Window A");
    defer window_a.deinit();
    const cascade_next = window_a.cascadeFrom(cascade_start);
    var ctx_a = WinCtx{ .label = "Window A" };
    try window_a.setCloseHandler(@ptrCast(&ctx_a), onClose);

    var webview_a = try wkz.webview.WebView.init();
    defer webview_a.deinit();
    webview_a.attach(window_a);
    try webview_a.loadHTMLString(
        "<body style='background:#1a1a2e;color:#eee;font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0'><h1>Window A</h1></body>",
    );

    // Window B — ctx_b must not move after setCloseHandler (stack-pinned here).
    var window_b = try wkz.window.Window.init(800, 600, "Window B");
    defer window_b.deinit();
    _ = window_b.cascadeFrom(cascade_next);
    var ctx_b = WinCtx{ .label = "Window B" };
    try window_b.setCloseHandler(@ptrCast(&ctx_b), onClose);

    var webview_b = try wkz.webview.WebView.init();
    defer webview_b.deinit();
    webview_b.attach(window_b);
    try webview_b.loadHTMLString(
        "<body style='background:#2e1a1a;color:#eee;font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0'><h1>Window B</h1></body>",
    );

    app.activate();
    app.run(); // blocks; process exits when last window closes or Cmd+Q
}
