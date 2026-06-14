const std = @import("std");
const wkz = @import("wkz");
const build_options = @import("build_options");
const dist_assets = @import("dist_assets");

pub fn main() !void {
    std.log.info("wkz basic example — dev mode: {}", .{build_options.dev});

    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();

    var app = try wkz.app.App.init();

    try app.installDefaultMenu("basic");

    const window = try wkz.window.Window.init(.{ .width = 900, .height = 600, .title = "basic" });

    const webview = if (build_options.dev) blk: {
        break :blk try wkz.webview.WebView.init();
    } else blk: {
        var scheme_handler = try wkz.scheme.SchemeHandler.init(&dist_assets.asset_map);
        break :blk try wkz.webview.WebView.initWithSchemeHandler(scheme_handler.object(), "app");
    };
    webview.attach(window);

    var bridge = try wkz.bridge.Bridge.init(
        gpa.allocator(),
        webview.userContentController(),
        webview.ns_webview,
    );
    try bridge.attach();

    try bridge.registerHandler("ping", struct {
        fn handle(b: *wkz.bridge.Bridge, _: std.json.Value, id: ?i64) void {
            if (id) |i| b.resolve(i, "\"pong\"") catch {};
        }
    }.handle);

    if (build_options.dev) {
        try webview.loadURL("http://localhost:5173");
    } else {
        try webview.loadURL("app://local/index.html");
    }

    app.activate();
    app.run();
}
