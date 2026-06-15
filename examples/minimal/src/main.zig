const wkz = @import("wkz");

pub fn main() !void {
    var app = try wkz.app.App.init();
    try app.installDefaultMenu("minimal");

    var window = try wkz.window.Window.init(.{ .width = 800, .height = 600, .title = "minimal" });
    defer window.deinit();

    var webview = try wkz.webview.WebView.init();
    defer webview.deinit();

    webview.attach(window);
    try webview.loadHTMLString("<h1>Hello from wkz</h1>");

    app.activate();
    app.run(); // blocks; process exits via Cmd+Q / terminate:
}
