# wkz

> **Requires Zig 0.16.x.** This is the only supported toolchain — the project is pinned to it and will not build on other versions. **Not production ready** (pre-v0.1).

A pure-Zig macOS desktop shell library: **AppKit + WKWebView** driven directly through the Objective-C runtime (via [mitchellh/zig-objc](https://github.com/mitchellh/zig-objc)), with a typed bidirectional **JS↔Zig bridge**. The frontend is framework-agnostic (Vite in dev, embedded assets in prod). No Swift, no compiled Objective-C, no C glue.

Think *"the [wry](https://github.com/tauri-apps/wry) layer of Tauri, for macOS, in Zig"*.

## Requirements

- **Zig 0.16.x** — verify with `zig version`; no other version is supported.
- **Xcode Command Line Tools** — `xcode-select --install` (macOS frameworks + SDK).
- **Bun** — for the Vite frontend in `examples/basic/`; optional unless you work on that example. Install from https://bun.sh.

## Quick start

```sh
zig build test                      # run all library tests (headless)
zig build docs                      # generate API docs → zig-out/docs/
# then serve (file:// is blocked by CORS):
python3 -m http.server -d zig-out/docs 8080  # open http://localhost:8080

# run the basic example in dev mode (one command)
cd examples/basic
zig build dev                       # starts Vite + app together

# or manually (two terminals):
zig build run -Ddev=true            # dev: loads http://localhost:5173
cd frontend && bun run dev          # start the Vite dev server
```

## Contributing

Enable the git hooks (one-time setup) — they regenerate the API docs after each commit:

```sh
git config core.hooksPath .githooks
```

In examples that embed a frontend, dev vs prod is the **`-Ddev` build option**, not a runtime switch:

- `-Ddev=true` — the WKWebView loads `http://localhost:5173`.
- release (default) — an `app://` URL scheme handler serves `@embedFile`'d Vite output.

## Architecture

| Path | Responsibility |
|------|----------------|
| `src/app.zig` | NSApplication bootstrap: activation policy, run loop, `setMenuBar`/`installDefaultMenu`. |
| `src/menu.zig` | Menu API: `MenuBarConfig` types, `WkzMenuTarget` ObjC class, action dispatch. |
| `src/window.zig` | NSWindow: titled/closable/resizable, centered, makeKeyAndOrderFront. |
| `src/webview.zig` | WKWebView filling contentView, configuration, content loading. |
| `src/bridge.zig` | Typed JS↔Zig bridge: script message handler, dispatch, RPC correlation. |
| `src/scheme.zig` | `app://` WKURLSchemeHandler serving embedded `dist/` assets in prod. |
| `src/objc_helpers.zig` | Objective-C runtime glue (class creation, selectors, encodings). |
| `src/root.zig` | Public API surface — re-exports the supported types/functions. |
| `bridge-js/` | Typed TS client (`@wkz/bridge`): `invoke<T>(method, params)`. |
| `tools/gen_assets.zig` | Build-time code generator: walks `dist/` and emits Zig with `@embedFile` entries. |
| `examples/basic/` | Full example: bridge, scheme handler, embedded Vite frontend, `.app` bundle. |

## Dependency

The only external dependency is **[mitchellh/zig-objc](https://github.com/mitchellh/zig-objc)**, pinned by commit hash `c8de82ff80281215ad92900866dab7103a8efa8b` in `build.zig.zon`. No other dependencies. No Swift, no compiled Objective-C, no C glue files.

## Design rules

1. **Main thread only.** All AppKit/WebKit calls happen on the main thread; the run loop owns it.
2. **No ARC.** Every `alloc`/`new`/`copy`/`retain` is paired with a `release` via `defer`/`errdefer` on every path, including errors.
3. **No Objective-C blocks.** Pass `nil` completion handlers; deliver responses back through the JS→Zig channel.
4. **Allocator-first.** Every allocating function takes an `Allocator`.
5. **`-Ddev` is the dev/prod switch**, never a runtime env branch.

## Using wkz as a dependency

Fetch and pin the hash in one step:

```sh
zig fetch --save https://github.com/polymorphl/wkz/archive/v0.1.0.tar.gz
```

This writes the `.url` and `.hash` into your `build.zig.zon` automatically. Then wire it in `build.zig`:

```zig
const wkz_dep = b.dependency("wkz", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("wkz", wkz_dep.module("wkz"));
// AppKit, WebKit, Foundation, libobjc are linked transitively — nothing else needed.
```

Then in your Zig source — a window in ~10 lines:

```zig
const wkz = @import("wkz");

pub fn main() !void {
    var app = try wkz.app.App.init();
    try app.installDefaultMenu("MyApp");

    var window = try wkz.window.Window.init(.{ .width = 800, .height = 600, .title = "MyApp" });
    defer window.deinit();

    var webview = try wkz.webview.WebView.init();
    defer webview.deinit();

    webview.attach(window);
    try webview.loadHTMLString("<h1>Hello from wkz</h1>");

    app.activate();
    app.run(); // blocks — exits via Cmd+Q
}
```

wkz is a pure macOS/ObjC layer — no frontend or build pipeline is imposed. Load content however you like: `loadHTMLString`, `loadURL` to a dev server, or wire up your own `SchemeHandler` for embedded assets.

## Examples

Each example is a standalone Zig package using wkz as a local path dependency — runnable directly from this repo.

| Example | What it shows |
|---------|---------------|
| [`examples/basic/`](examples/basic/) | Full-stack example: bridge, `app://` scheme handler, embedded Vite frontend, `.app` bundle. Supports `-Ddev=true` for hot-reload. |
| [`examples/minimal/`](examples/minimal/) | Smallest possible app: window + WKWebView + inline HTML. No bridge, no assets. |
| [`examples/updater/`](examples/updater/) | Auto-updater wired through the JS↔Zig bridge: check / download / install flow with a sample manifest. |
| [`examples/fs/`](examples/fs/) | File system bridge: native open dialog (NSOpenPanel), read text/binary, write text/binary, file-type filtering. |
| [`examples/clipboard/`](examples/clipboard/) | Clipboard bridge: read and write plain text via `clipboard.readText` / `clipboard.writeText` (NSPasteboard). |
| [`examples/dragdrop/`](examples/dragdrop/) | Drag & drop: drop files from Finder onto the window — paths emitted as `dragdrop.filesDropped` bridge event. |
| [`examples/alert/`](examples/alert/) | Alert dialogs: native NSAlert via `alert.show` bridge handler — simple, confirmation (critical), and informational scenarios. |
| [`examples/statusitem/`](examples/statusitem/) | Menu-bar status item: NSStatusItem with title, SF Symbol icon, and `statusitem.click` events via `wkz.statusitem`. |
| [`examples/titlebar/`](examples/titlebar/) | Titlebar styles: two windows side by side demonstrating `.transparent` and `.hidden` `TitlebarStyle` variants. |
| [`examples/menu/`](examples/menu/) | Menu API: full `NSMenuBar` with Zig callback handler, native selectors, and standard Edit/Window menus. |
| [`examples/multi_window/`](examples/multi_window/) | Multi-window: two independent windows with close callbacks and quit-on-last-close policy. |
| [`examples/events/`](examples/events/) | Window events: focus/blur pushed from Zig to JS via NSNotificationCenter — `window.focused` / `window.blurred` bridge events. |
| [`examples/shell/`](examples/shell/) | Shell integration: open URLs in the default browser or registered scheme handler via `shell.open` (NSWorkspace). |
| [`examples/notifications/`](examples/notifications/) | Local notifications: request permission and deliver banners via `notifications.requestPermission` / `notifications.send` (UNUserNotificationCenter). |

See each folder's `README.md` for full instructions.

## Status

Pre-v0.1, built milestone by milestone — see `TASK.md`. **Not production ready.**
