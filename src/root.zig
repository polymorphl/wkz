//! wkz — public API surface of the library.
//!
//! Responsibility: re-export the stable, supported types/functions so consumers
//! write `@import("wkz")` and nothing deeper. Internal modules
//! (objc_helpers, scheme, ...) stay private unless promoted here.
//!
//! Nothing is implemented yet — this is the M1.1 scaffold. Real API lands in
//! M1.2+ and is documented per-declaration with ownership rules.

const std = @import("std");

pub const app = @import("app.zig");
pub const window = @import("window.zig");
pub const webview = @import("webview.zig");
pub const bridge = @import("bridge.zig");

// `scheme` is now part of the public API surface (M4.1): consumers use
// `AssetMap`, `AssetEntry`, `SchemeHandler`, and `mimeForPath` directly.
pub const scheme = @import("scheme.zig");

// Internal module: not part of the public surface, but kept in the compile
// and test graph so its tests run.
const objc_helpers = @import("objc_helpers.zig");

test {
    std.testing.refAllDecls(@This());
    _ = objc_helpers;
}
