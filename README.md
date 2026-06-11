# wkz

> **Requires Zig 0.16.x.** This is the only supported toolchain — the project is pinned to it and will not build on other versions. **Not production ready** (pre-v0.1).

A pure-Zig macOS desktop shell library: **AppKit + WKWebView** driven directly through the Objective-C runtime (via [mitchellh/zig-objc](https://github.com/mitchellh/zig-objc)), with a typed bidirectional **JS↔Zig bridge**. The frontend is framework-agnostic (Vite in dev, embedded assets in prod). No Swift, no compiled Objective-C, no C glue.

Think *"the [wry](https://github.com/tauri-apps/wry) layer of Tauri, for macOS, in Zig"*.

## Requirements

- **Zig 0.16.x** — verify with `zig version`; no other version is supported.
- **Xcode Command Line Tools** — `xcode-select --install` (macOS frameworks + SDK).
- **Node.js** — for the Vite frontend; optional unless you work on the UI.

## Quick start

```sh
zig build                  # build the library + example
zig build run -Ddev=true   # run against the Vite dev server (http://localhost:5173)
zig build test             # run all tests (headless)
cd frontend && npm run dev  # start the Vite dev server
```

Dev vs prod is the **`-Ddev` build option**, not a runtime switch:

- `-Ddev=true` — the WKWebView loads `http://localhost:5173`.
- release (default) — an `app://` URL scheme handler serves `@embedFile`'d Vite output.

## Architecture

| Path | Responsibility |
|------|----------------|
| `src/main.zig` | Runnable example; what `zig build run` launches. |
| `src/app.zig` | NSApplication bootstrap: activation policy, menu (Cmd+Q), run loop. |
| `src/window.zig` | NSWindow: titled/closable/resizable, centered, makeKeyAndOrderFront. |
| `src/webview.zig` | WKWebView filling contentView, configuration, content loading. |
| `src/bridge.zig` | Typed JS↔Zig bridge: script message handler, dispatch, RPC correlation. |
| `src/scheme.zig` | `app://` WKURLSchemeHandler serving embedded `dist/` assets in prod. |
| `src/objc_helpers.zig` | Objective-C runtime glue (class creation, selectors, encodings). |
| `src/root.zig` | Public API surface — re-exports the supported types/functions. |
| `frontend/` | Framework-agnostic web UI (Vite, vanilla-ts). |
| `bridge-js/` | Typed TS client (`@wkz/bridge`): `invoke<T>(method, params)`. |

## Dependency

The only external dependency is **[mitchellh/zig-objc](https://github.com/mitchellh/zig-objc)**, pinned by commit hash `c8de82ff80281215ad92900866dab7103a8efa8b` in `build.zig.zon`. No other dependencies. No Swift, no compiled Objective-C, no C glue files.

## Design rules

1. **Main thread only.** All AppKit/WebKit calls happen on the main thread; the run loop owns it.
2. **No ARC.** Every `alloc`/`new`/`copy`/`retain` is paired with a `release` via `defer`/`errdefer` on every path, including errors.
3. **No Objective-C blocks.** Pass `nil` completion handlers; deliver responses back through the JS→Zig channel.
4. **Allocator-first.** Every allocating function takes an `Allocator`.
5. **`-Ddev` is the dev/prod switch**, never a runtime env branch.

## Status

Pre-v0.1, built milestone by milestone — see `TASK.md`. **Not production ready.**
