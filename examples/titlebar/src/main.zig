//! Titlebar style example for wkz.
//!
//! Opens two windows side by side demonstrating the two non-default
//! TitlebarStyle variants:
//!
//!   .transparent — titlebar transparent, title text visible, web content
//!                  extends under the titlebar area (~28 pt from top).
//!
//!   .hidden      — titlebar transparent, title hidden, full-bleed web
//!                  content fills 100% of the window including traffic-lights
//!                  area. Frontend reserves the safe area via CSS padding.
//!
//! Main thread only. No bridge used.

const std = @import("std");
const wkz = @import("wkz");

pub fn main() !void {
    var app = try wkz.app.App.init();
    defer app.deinit();
    try app.installDefaultMenu("wkz titlebar");

    // Window A — .transparent: title bar visible, content extends under it.
    var win_a = try wkz.window.Window.init(.{
        .width = 700,
        .height = 500,
        .title = "Transparent titlebar",
        .titlebar = .transparent,
    });
    defer win_a.deinit();
    const cascade_start = wkz.window.CGPoint{ .x = 80, .y = 650 };
    const cascade_next = win_a.cascadeFrom(cascade_start);

    var wv_a = try wkz.webview.WebView.init();
    defer wv_a.deinit();
    wv_a.attach(win_a);
    try wv_a.loadHTMLString(
        "<style>*{margin:0;padding:0;box-sizing:border-box}" ++
            "body{background:#1a1a2e;color:#eee;font-family:system-ui;" ++
            "padding-top:28px}" // reserve space for transparent titlebar
        ++
            ".label{display:flex;align-items:center;justify-content:center;" ++
            "height:calc(100vh - 28px);flex-direction:column;gap:12px}" ++
            "h1{font-size:22px}p{font-size:13px;color:#aaa;text-align:center}</style>" ++
            "<div class='label'><h1>.transparent</h1>" ++
            "<p>Title bar is transparent.<br>Web content starts at 28 pt top padding.<br>" ++
            "Window title is still visible in the title bar.</p></div>",
    );

    // Window B — .hidden: no title, full-bleed content, traffic lights float over web UI.
    var win_b = try wkz.window.Window.init(.{
        .width = 700,
        .height = 500,
        .title = "Hidden titlebar",
        .titlebar = .hidden,
    });
    defer win_b.deinit();
    _ = win_b.cascadeFrom(cascade_next);

    var wv_b = try wkz.webview.WebView.init();
    defer wv_b.deinit();
    wv_b.attach(win_b);
    try wv_b.loadHTMLString(
        "<style>*{margin:0;padding:0;box-sizing:border-box}" ++
            "body{background:#2e1a2e;color:#eee;font-family:system-ui;" ++
            "padding-top:28px}" // reserve space for traffic lights
        ++
            ".label{display:flex;align-items:center;justify-content:center;" ++
            "height:calc(100vh - 28px);flex-direction:column;gap:12px}" ++
            "h1{font-size:22px}p{font-size:13px;color:#aaa;text-align:center}</style>" ++
            "<div class='label'><h1>.hidden</h1>" ++
            "<p>Title bar is hidden.<br>Web content fills the full window.<br>" ++
            "Traffic lights float over the web UI.<br>" ++
            "Frontend reserves 28 pt for them via CSS padding.</p></div>",
    );

    app.activate();
    app.run();
}
