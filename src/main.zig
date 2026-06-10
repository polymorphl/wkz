//! Runnable example for the wkz library.
//!
//! Responsibility: the smallest program that opens a window with a WKWebView,
//! exercising the public wkz API end-to-end. This is what `zig build run`
//! launches. It boots the NSApplication, creates a centered window, fills its
//! contentView with a WKWebView, loads an inline "hello" page, foregrounds the
//! app, and enters the run loop. Main thread only.

const std = @import("std");
const wkz = @import("wkz");
const build_options = @import("build_options");

/// The inline page shown by the example. Self-contained HTML, no external
/// assets: M1 has no app:// scheme handler and no Vite wiring yet (those land
/// in M3/M4, at which point this example will branch on `build_options.dev`
/// between the Vite dev server and the embedded `dist/` bundle). For now the
/// same inline page is loaded in both dev and prod builds.
const hello_html: [:0]const u8 =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="utf-8" />
    \\  <meta name="viewport" content="width=device-width, initial-scale=1" />
    \\  <title>wkz</title>
    \\  <style>
    \\    html, body { height: 100%; margin: 0; }
    \\    body {
    \\      display: flex; align-items: center; justify-content: center;
    \\      font-family: -apple-system, system-ui, sans-serif;
    \\      background: #0b0d12; color: #e6e8ee;
    \\    }
    \\    h1 { font-size: 3rem; font-weight: 600; letter-spacing: 0.05em; }
    \\  </style>
    \\</head>
    \\<body>
    \\  <h1>wkz</h1>
    \\</body>
    \\</html>
;

pub fn main() !void {
    std.log.info("wkz example — dev mode: {}", .{build_options.dev});

    // Order matters: the shared NSApplication must exist before any window is
    // created, so App.init() runs first.
    const app = try wkz.app.App.init();

    // Centered, titled/closable/resizable window. It must outlive the run loop;
    // see the lifetime note on `run()` below for why no deinit is called.
    const window = try wkz.window.Window.init(900, 600, "wkz");

    // WKWebView, attached to (and filling) the window's contentView, loading the
    // inline page. attach() reads the contentView's bounds, so the window must
    // already exist — which it does, by the ordering above.
    const webview = try wkz.webview.WebView.init();
    webview.attach(window);
    try webview.loadHTMLString(hello_html);

    // Foreground the app, then enter the AppKit run loop. `run()` blocks until
    // the user quits (Cmd+Q -> `terminate:`), and AppKit's `terminate:` exits
    // the process directly — it does NOT return control to Zig. Therefore no
    // `defer window.deinit()` / `defer webview.deinit()` is installed: such a
    // defer would be dead code (it could never fire), and the OS reclaims the
    // process's memory on exit. The window and webview are intentionally kept
    // alive for the entire run-loop / process lifetime.
    app.activate();
    app.run();
}

test {
    std.testing.refAllDecls(@This());
}
