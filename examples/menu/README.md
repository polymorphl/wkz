# examples/menu

Demonstrates the wkz Menu API: a full `NSMenuBar` with a custom File menu, a Zig callback handler, and the standard Edit and Window menus.

## Prerequisites

- macOS (arm64 or x86_64)
- Zig 0.16.x (`zig version` must report `0.16.`)

## Run

```sh
cd examples/menu
zig build run
```

Opens an 800×600 window. Try:

- **Cmd+N** (File > New) — fires a Zig callback; logs `File > New triggered` to stdout each time.
- **Edit menu** (Undo, Redo, Cut, Copy, Paste, Select All) — AppKit first-responder chain; WKWebView handles these automatically.
- **Window menu** (Minimize, Zoom, Close) — standard AppKit selectors.
- **Cmd+Q** — quits.

## Build only

```sh
zig build
# binary at zig-out/bin/menu_example
```

## How it works

`src/main.zig` uses `App.setMenuBar` with a `MenuBarConfig`:

```
App.init()          — boots NSApplication
app.setMenuBar()    — installs NSMenuBar from config:
  AppMenuConfig     — app menu with Hide/Quit defaults
  menus[File]       — custom File menu: New (Zig callback), separator, Close (selector)
  standard_edit_menu: true   — Undo/Redo/Cut/Copy/Paste/SelectAll via AppKit
  standard_window_menu: true — Minimize/Zoom/Close via AppKit
Window.init()       — creates a titled, resizable NSWindow
WebView.init()      — creates a WKWebView filling the window
app.run()           — enters the AppKit run loop
```

### MenuAction variants

| Variant | Used for | Example |
|---------|----------|---------|
| `.selector` | Native AppKit selector (first-responder chain) | `"performClose:"` |
| `.zig` | Zig function called on main thread | `onFileNew` logs to stdout |
| `.bridge` | Dispatches to JS bridge handler | (not shown — see `examples/fs/`) |

wkz is consumed as a path dependency (`../..` in `build.zig.zon`).
