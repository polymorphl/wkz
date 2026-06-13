# examples/multi_window

Two independent windows, each with a WKWebView and a close callback. Demonstrates `App.setQuitOnLastWindowClosed` and `Window.setCloseHandler`.

## Prerequisites

- macOS (arm64 or x86_64)
- Zig 0.16.x (`zig version` must report `0.16.`)

## Run

```sh
cd examples/multi_window
zig build run
```

Opens two 800×600 windows (blue "Window A", red "Window B"), cascaded so they don't overlap. Close either window — the app stays alive. Close the last one — the app quits. Stdout logs which window closed. Quit with **Cmd+Q** at any time.

## Build only

```sh
zig build
# binary at zig-out/bin/multi_window
```

## How it works

`src/main.zig` uses the wkz public API:

```
App.init()                          — boots NSApplication
app.setQuitOnLastWindowClosed(true) — registers NSApplicationDelegate; quits when last window closes
Window.init()                       — creates a titled, resizable NSWindow (×2)
window.cascadeFrom(point)           — positions window from a cascade origin; returns next cascade point
window.setPosition(x, y)            — explicit coordinate positioning (alternative to cascadeFrom)
window.setCloseHandler(ctx, fn)     — registers NSWindowDelegate; fires fn(ctx) on close (×2)
WebView.init() + attach()           — creates a WKWebView filling each window (×2)
app.run()                           — enters the AppKit run loop
```

wkz is consumed as a path dependency (`../..` in `build.zig.zon`).
