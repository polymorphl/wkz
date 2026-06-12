# examples/minimal

Minimal wkz consumer: opens a window with a WKWebView and loads an inline HTML string. No bridge, no assets, no build options.

## Prerequisites

- macOS (arm64 or x86_64)
- Zig 0.16.x (`zig version` must report `0.16.`)

## Run

```sh
cd examples/minimal
zig build run
```

Opens an 800×600 window displaying `Hello from wkz`. Quit with **Cmd+Q**.

## Build only

```sh
zig build
# binary at zig-out/bin/minimal
```

## How it works

`src/main.zig` calls the wkz public API directly:

```
App.init()            — boots NSApplication
Window.init()         — creates a titled, resizable NSWindow
WebView.init()        — creates a WKWebView filling the window
webview.loadHTMLString() — loads inline HTML
app.run()             — enters the AppKit run loop (blocks until Cmd+Q)
```

wkz is consumed as a path dependency (`../..` in `build.zig.zon`).
