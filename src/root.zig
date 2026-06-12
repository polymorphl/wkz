//! wkz public API surface.
//!
//! Re-exports the supported types and functions from the wkz library modules.
//! Consumers import this as `@import("wkz")`.
//!
//! Exported namespaces:
//!   - `app`     — NSApplication bootstrap (`App.init`, `activate`, `run`)
//!   - `window`  — NSWindow creation (`Window.init`, `setTitle`, `deinit`)
//!   - `webview` — WKWebView management (`WebView.init`, `attach`, `loadURL`, …)
//!   - `bridge`  — JS↔Zig typed bridge (`Bridge.init`, `registerHandler`, …)
//!   - `scheme`  — `app://` scheme handler (`SchemeHandler`, `AssetMap`, `mimeForPath`)

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

// Updater module: self-update support. Exported so consumers can use
// `wkz.updater.Updater`, `wkz.updater.UpdaterConfig`, etc.
pub const updater = @import("updater.zig");

test {
    std.testing.refAllDecls(@This());
    _ = objc_helpers;
}
