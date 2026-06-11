const wkz = @import("wkz");

pub fn main() !void {
    var app = try wkz.app.App.init();

    var window = try wkz.window.Window.init(800, 600, "minimal");
    defer window.deinit();

    var webview = try wkz.webview.WebView.init();
    defer webview.deinit();

    webview.attach(window);
    try webview.loadHTMLString("<h1>Hello from wkz</h1>");

    app.activate();
    app.run(); // blocks; process exits via Cmd+Q / terminate:
}
