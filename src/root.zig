//! wkz public API surface.
//!
//! Re-exports the supported types and functions from the wkz library modules.
//! Consumers import this as `@import("wkz")`.
//!
//! Exported namespaces:
//!   - `app`     — NSApplication bootstrap (`App.init`, `activate`, `run`, `deinit`, `setQuitOnLastWindowClosed`, `setMenuBar`, `installDefaultMenu`)
//!   - `window`  — NSWindow creation (`Window.init(WindowConfig)`, `TitlebarStyle`, `WindowConfig`, `setTitle`, `deinit`, `setCloseHandler`, `setPosition`, `cascadeFrom`)
//!   - `webview` — WKWebView management (`WebView.init`, `attach`, `loadURL`, …)
//!   - `bridge`  — JS↔Zig typed bridge (`Bridge.init`, `registerHandler`, …)
//!   - `scheme`  — `app://` scheme handler (`SchemeHandler`, `AssetMap`, `mimeForPath`)
//!   - `fs`      — file system bridge handlers (`Fs.init`, `registerBridgeHandlers`)
//!   - `menu`    — NSMenuBar construction (`MenuAction`, `MenuItem`, `AppMenuConfig`, `MenuBarConfig`, `setMenuBar`, `installDefaultMenu`)
//!   - `alert`   — NSAlert modal dialog (`registerAlertHandler`)
//!   - `statusitem` — NSStatusItem menu-bar status item (`StatusItem.init`, `registerBridgeHandlers`, `deinit`)

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

// Fs module: file system bridge handlers (open dialog, read, write).
pub const fs = @import("fs.zig");

// Menu module: NSMenuBar construction and menu action routing.
pub const menu = @import("menu.zig");

// Alert module: native NSAlert modal dialog via alert.show bridge handler.
pub const alert = @import("alert.zig");

// StatusItem module: NSStatusBar item bridge handlers (set, remove).
pub const statusitem = @import("statusitem.zig");

// DragDrop module: transparent file drag-and-drop overlay.
pub const dragdrop = @import("dragdrop.zig");

test {
    std.testing.refAllDecls(@This());
    _ = objc_helpers;
}
