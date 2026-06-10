//! NSWindow creation and configuration.
//!
//! Responsibility: build an NSWindow (titled, closable, resizable), center it,
//! and bring it to front via makeKeyAndOrderFront. Holds the window's content
//! view that the WKWebView fills. Main thread only; release paired on deinit.
//!
//! M1.1 scaffold: no implementation yet (lands in M1.3).

const std = @import("std");
const objc = @import("objc");

comptime {
    _ = objc;
}

test {
    std.testing.refAllDecls(@This());
}
