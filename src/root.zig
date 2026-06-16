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
//!   - `clipboard`  — NSPasteboard clipboard access (`registerClipboardHandlers`)
//!   - `shell`         — NSWorkspace shell integration (`registerHandlers`)
//!   - `notifications` — UNUserNotificationCenter local notifications (`registerHandlers`)

const std = @import("std");

/// NSApplication bootstrap: `App.init`, `activate`, `run`, `deinit`,
/// `setQuitOnLastWindowClosed`, `setMenuBar`, `installDefaultMenu`.
pub const app = @import("app.zig");

/// NSWindow creation and management: `Window.init(WindowConfig)`,
/// `TitlebarStyle`, `WindowConfig`, `setTitle`, `deinit`,
/// `setCloseHandler`, `setPosition`, `cascadeFrom`.
pub const window = @import("window.zig");

/// WKWebView management: `WebView.init`, `attach`, `loadURL`,
/// `loadHTMLString`, `userContentController`, `deinit`.
pub const webview = @import("webview.zig");

/// Typed JS↔Zig bridge: `Bridge.init`, `attach`, `registerHandler`,
/// `resolve`, `evaluate`, `deinit`.
pub const bridge = @import("bridge.zig");

/// `app://` URL scheme handler serving `@embedFile`'d Vite output:
/// `SchemeHandler`, `AssetMap`, `AssetMapEntry`, `AssetEntry`, `mimeForPath`.
pub const scheme = @import("scheme.zig");

// Internal module: not part of the public surface, but kept in the compile
// and test graph so its tests run.
const objc_helpers = @import("objc_helpers.zig");

/// Self-update support: `Updater`, `UpdaterConfig`, `CheckedUpdate`,
/// `UpdateInfo`, `ManifestSource`.
pub const updater = @import("updater.zig");

/// File system bridge handlers — native open/save dialogs, read/write text
/// and binary: `Fs.init`, `registerBridgeHandlers`.
pub const fs = @import("fs.zig");

/// NSMenuBar construction and menu action routing: `MenuAction`, `MenuItem`,
/// `AppMenuConfig`, `MenuBarConfig`, `buildMenuBar`, `freeActionTable`.
pub const menu = @import("menu.zig");

/// Native NSAlert modal dialog: `registerAlertHandler`.
pub const alert = @import("alert.zig");

/// NSStatusBar item bridge: `StatusItem.init`, `registerBridgeHandlers`,
/// `deinit`. Emits `statusitem.click` events to JS.
pub const statusitem = @import("statusitem.zig");

/// Transparent file drag-and-drop overlay: `DragDrop.init`, `deinit`.
/// Emits `dragdrop.filesDropped` events to JS.
pub const dragdrop = @import("dragdrop.zig");

/// NSPasteboard clipboard access: `registerClipboardHandlers`.
/// Handles `clipboard.readText` and `clipboard.writeText` from JS.
pub const clipboard = @import("clipboard.zig");

/// Window focus/blur events via NSNotificationCenter: `WindowEvents.init`,
/// `deinit`. Emits `window.focused` / `window.blurred` events to JS.
pub const events = @import("events.zig");

/// Shell integration: `registerHandlers`. Handles `shell.open` from JS,
/// opening URLs via `NSWorkspace openURL:`.
pub const shell = @import("shell.zig");

/// Local notification support: `registerHandlers`. Handles
/// `notifications.requestPermission` and `notifications.send` from JS via
/// `UNUserNotificationCenter`.
pub const notifications = @import("notifications.zig");

test {
    std.testing.refAllDecls(@This());
    _ = objc_helpers;
}
