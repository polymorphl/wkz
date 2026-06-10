# wkz

> **Requires Zig 0.16.x.** This is the only supported toolchain — the project is pinned to it and will not build on other versions. ⚠️ **Not production ready** (pre-v0.1).

A pure-Zig macOS desktop shell library: **AppKit + WKWebView** driven directly through the Objective-C runtime (via [mitchellh/zig-objc](https://github.com/mitchellh/zig-objc)), with a typed bidirectional **JS↔Zig bridge**. The frontend is framework-agnostic (Vite in dev, embedded assets in prod). No Swift, no compiled Objective-C, no C glue.

Think *"the [wry](https://github.com/tauri-apps/wry) layer of Tauri, for macOS, in Zig"*.

## Requirements

- **Zig 0.16.x** (verify with `zig version`).
- **Xcode Command Line Tools** (`xcode-select --install`) — for the macOS frameworks and SDK.
- **Node.js** (for the Vite frontend), optional unless you work on the UI.

## Build

```sh
zig build                  # build the library + example
zig build run -Ddev=true   # run against the Vite dev server (http://localhost:5173)
zig build test             # run all tests (headless)
cd frontend && npm run dev  # start the Vite dev server
```

Dev vs prod is the **`-Ddev` build option**, not a runtime switch:

- `-Ddev=true` → the WKWebView loads `http://localhost:5173`.
- release (default) → an `app://` URL scheme handler serves `@embedFile`'d Vite output.

## Layout

```
src/
  main.zig         runnable example
  app.zig          NSApplication bootstrap + run loop
  window.zig       NSWindow
  webview.zig      WKWebView
  bridge.zig       typed JS<->Zig bridge
  scheme.zig       app:// scheme handler (embedded assets)
  objc_helpers.zig Objective-C runtime glue
  root.zig         public API surface
frontend/          framework-agnostic web UI (Vite, vanilla-ts)
bridge-js/         typed TS client (@wkz/bridge)
```

## Status

Pre-v0.1, built milestone by milestone — see `TASK.md`. **Not production ready.**
