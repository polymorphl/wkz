# wkz — Task Tracker

Single source of truth for work. Statuses: `TODO → IN_PROGRESS → IN_REVIEW → TESTING → DONE | BLOCKED(reason)`.

## Current focus

**M1.2 — `app.zig` NSApplication bootstrap.** (M1.1 scaffold is DONE.)

---

## M1 — Window + WebView

| ID | Task | Status |
|----|------|--------|
| 1.1 | Scaffold green: build.zig (wkz module + example, frameworks, `-Ddev`, test step), src stubs, zig-objc pinned, Vite + bridge-js, gitignore/README/CI | DONE |
| 1.2 | `app.zig` NSApplication bootstrap, activation policy `.regular`, menu with Cmd+Q | TODO |
| 1.3 | `window.zig` NSWindow titled/closable/resizable, centered, makeKeyAndOrderFront | TODO |
| 1.4 | `webview.zig` WKWebView filling contentView, loadHTMLString inline page, inspectable=true | TODO |
| 1.5 | Example in `main.zig`; `zig build run` opens a window | TODO |

## M2 — JS→Zig bridge

| ID | Task | Status |
|----|------|--------|
| 2.1 | `objc_helpers.zig` runtime class creation (allocateClassPair + method registration), unit-tested | TODO |
| 2.2 | ScriptMessageHandler class implementing `userContentController:didReceiveScriptMessage:`, registered as `"bridge"` | TODO |
| 2.3 | NSDictionary → Zig extraction, std.json parse, dispatch table | TODO |
| 2.4 | Malformed input logs, never crashes | TODO |

## M3 — Typed RPC + Vite

| ID | Task | Status |
|----|------|--------|
| 3.1 | `evaluateJavaScript` (nil handler) + `__resolve(id, result)` convention | TODO |
| 3.2 | `bridge.zig` public API `registerHandler(comptime method, fn)` with request/response correlation | TODO |
| 3.3 | bridge-js TS client `invoke<T>()`, HMR-idempotent (`import.meta.hot.dispose`) | TODO |
| 3.4 | `-Ddev` wiring + Info.plist `NSAllowsLocalNetworking` documented | TODO |
| 3.5 | frontend demo round-trip | TODO |

## M4 — Bundle

| ID | Task | Status |
|----|------|--------|
| 4.1 | `scheme.zig` WKURLSchemeHandler serving embedded `dist/` at `app://local` | TODO |
| 4.2 | Build step runs `vite build` + embeds output, zero external assets | TODO |
| 4.3 | `.app` bundle generation (`Contents/MacOS`, Info.plist) | TODO |
| 4.4 | Ad-hoc codesign, launches from Finder | TODO |

## M5 — v0.1

| ID | Task | Status |
|----|------|--------|
| 5.1 | API review (naming, ownership docs, error sets) | TODO |
| 5.2 | README with Zig pin on first screen | TODO |
| 5.3 | CI macos runner with `mlugg/setup-zig` | TODO |
| 5.4 | Tag `v0.1.0` | TODO |

---

## Log

- M1.1 — orchestrator — scaffold created: build.zig (wkz module + example exe, AppKit/WebKit/Foundation/libobjc, `-Ddev` via build_options, test step), 7 src stubs (doc comment + refAllDecls), zig-objc pinned at `c8de82f`, Vite vanilla-ts frontend, `@wkz/bridge` TS stub, .gitignore/README/CI. `zig build` + `zig build test` green. → DONE

## Decisions

- **zig-objc ref**: pinned to commit `c8de82ff80281215ad92900866dab7103a8efa8b` (main HEAD, 2026-04-17). This is the first line that includes "Add Zig 0.16 compatibility" (`fd36c1c`) + the 0.16 translate-c bug fix (`41ea96c`); no 0.16-tagged release exists, so pin by hash rather than `master`.
- **`src/root.zig` added** as the public API aggregator (not in the original architecture list). Idiomatic Zig module root; re-exports app/window/webview/bridge and keeps scheme/objc_helpers internal but in the test graph.

## Blocked

- _(none)_
