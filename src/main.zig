//! Runnable example for the wkz library.
//!
//! Responsibility: the smallest program that opens a window with a WKWebView,
//! exercising the public wkz API end-to-end. This is what `zig build run`
//! launches. Real bootstrap lands in M1.5; for the M1.1 scaffold it only needs
//! to compile and link.

const std = @import("std");
const wkz = @import("wkz");
const build_options = @import("build_options");

pub fn main() !void {
    // M1.5 will boot the NSApplication run loop here via the wkz API.
    // For now keep the scaffold compiling and report the active build mode.
    std.log.info("wkz example — dev mode: {}", .{build_options.dev});
    _ = wkz;
}

test {
    std.testing.refAllDecls(@This());
}
