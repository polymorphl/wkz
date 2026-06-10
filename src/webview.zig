//! WKWebView creation, configuration, and content loading.
//!
//! Responsibility: build a WKWebView filling the window's content view, attach
//! the WKWebViewConfiguration (user content controller, scheme handler), set
//! inspectable=true, and load content — loadHTMLString / loadRequest (dev) /
//! app:// scheme (prod). Main thread only; release paired on deinit.
//!
//! M1.1 scaffold: no implementation yet (lands in M1.4).

const std = @import("std");
const objc = @import("objc");

comptime {
    _ = objc;
}

test {
    std.testing.refAllDecls(@This());
}
