//! Menu API example for wkz.
//!
//! Demonstrates:
//!   - installDefaultMenu: minimal app menu with Cmd+Q
//!   - MenuAction.zig: native Zig callback on a menu item
//!   - standard_edit_menu: AppKit Edit menu via first-responder chain
//!
//! All AppKit calls are on the main thread (run loop). No bridge used.

const std = @import("std");
const wkz = @import("wkz");

/// Context for the "File > New" Zig callback. Stack-pinned in main.
const FileNewCtx = struct {
    count: u32 = 0,
};

fn onFileNew(ptr: *anyopaque) void {
    const ctx: *FileNewCtx = @ptrCast(@alignCast(ptr));
    ctx.count += 1;
    std.log.info("File > New triggered (count={})", .{ctx.count});
}

pub fn main() !void {
    var app = try wkz.app.App.init();
    defer app.deinit();

    var ctx = FileNewCtx{};

    try app.setMenuBar(std.heap.page_allocator, .{
        .app = .{ .name = "wkz menu example" },
        .menus = &.{
            .{
                .title = "File",
                .items = &.{
                    .{ .item = .{
                        .title = "New",
                        .key = "n",
                        .action = .{ .zig = .{
                            .ctx = @ptrCast(&ctx),
                            .callback = onFileNew,
                        } },
                    } },
                    .separator,
                    .{ .item = .{
                        .title = "Close",
                        .key = "w",
                        .action = .{ .selector = "performClose:" },
                    } },
                },
            },
        },
        .standard_edit_menu = true,
        .standard_window_menu = true,
    });

    var window = try wkz.window.Window.init(800, 600, "wkz menu example");
    defer window.deinit();

    var webview = try wkz.webview.WebView.init();
    defer webview.deinit();
    webview.attach(window);
    try webview.loadHTMLString(
        "<body style='background:#0f1117;color:#eee;font-family:sans-serif;" ++
            "display:flex;align-items:center;justify-content:center;height:100vh;margin:0'>" ++
            "<div style='text-align:center'>" ++
            "<h1>Menu API demo</h1>" ++
            "<p>Try File > New (Cmd+N) — logs to stdout.<br>" ++
            "Edit menu (Undo/Redo/Cut/Copy/Paste/Select All) via AppKit first-responder chain.<br>" ++
            "Quit with Cmd+Q.</p>" ++
            "</div></body>",
    );

    app.activate();
    app.run();
}
