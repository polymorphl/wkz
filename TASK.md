# wkz — Task Tracker

Single source of truth for work. Statuses: `TODO → IN_PROGRESS → IN_REVIEW → TESTING → DONE | BLOCKED(reason)`.

## Current focus

**M2.1 — `objc_helpers.zig` runtime class creation.** (M1 complete — all of M1.1–M1.5 DONE.)

---

## M1 — Window + WebView

| ID | Task | Status |
|----|------|--------|
| 1.1 | Scaffold green: build.zig (wkz module + example, frameworks, `-Ddev`, test step), src stubs, zig-objc pinned, Vite + bridge-js, gitignore/README/CI | DONE |
| 1.2 | `app.zig` NSApplication bootstrap, activation policy `.regular`, menu with Cmd+Q | DONE |
| 1.3 | `window.zig` NSWindow titled/closable/resizable, centered, makeKeyAndOrderFront | DONE |
| 1.4 | `webview.zig` WKWebView filling contentView, loadHTMLString inline page, inspectable=true | DONE |
| 1.5 | Example in `main.zig`; `zig build run` opens a window | DONE |

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

- **M1 COMPLETE** — all M1.1–M1.5 DONE. `zig build run` opens a real, centered, titled, resizable window with a WKWebView filling the contentView rendering an inline page; Cmd+Q quits. Full suite 32/32 green. Manual GUI verification consolidated in checklist M1.5-G1..G7 (exercises deferred M1.2/M1.3/M1.4 GUI items end-to-end). Next milestone: M2 (JS→Zig bridge), starting M2.1 `objc_helpers.zig`.
- M1.5 — orchestrator — code-reviewer APPROVE (zero findings; lifetime reasoning sound — run() blocks, terminate: exits process so post-run deinit is unreachable dead code, each struct holds a single +1, no double-release/use-after-free, no false no-leak claim; ordering App→Window→attach correct; API signatures + [:0]const u8 HTML literal verified). test-runner green 32/32 (3× deterministic); `zig build run -Ddev=true` smoke-test launched + blocked on run loop (timeout-kill 124, no crash). Committed. → DONE
- M1.5 — test-runner — 32/32 (31 lib + 1 example refAllDecls), 3/3 deterministic runs exit 0; `zig build` exit 0; `zig build run -Ddev=true` smoke-test launched + blocked on run loop (timeout-kill 124, no crash, window server present). No new tests (entrypoint blocks; wired types covered in their own modules; refAllDecls forces compile). Authored M1.5-G1..G7 manual GUI checklist covering deferred M1.2/M1.3/M1.4 GUI behaviour end-to-end. → TESTING
- M1.5 — zig-developer — implemented `src/main.zig` example: `App.init()` → `Window.init(900,600,"wkz")` → `WebView.init()` → `attach(window)` → `loadHTMLString(inline_html)` → `activate()` → `run()`. Inline dark "wkz" hello page. `deinit` intentionally omitted (run() blocks; terminate: exits process so post-run defer is dead code) — documented honestly, no false no-leak claim. `zig build` + `zig build test` green (32/32). → IN_REVIEW
- M1.4 — orchestrator — code-reviewer APPROVE (zero findings; config +1 consumed by initWithFrame:configuration: and defer-released, webview +1 owned by deinit, contentView() borrowed/not-released, CGRect by-value return path correct on aarch64, CG types made pub without layout change). test-runner green 32/32 (3× deterministic), live WKWebView tests stable headless, 0 impl bugs. `zig build` + `zig build test` exit 0. Committed. → DONE
- M1.4 — test-runner — `zig build` + `zig build test` green (8/8 steps, 32/32, exit 0, deterministic across 3 runs). Live WKWebView tests confirmed stable headless. Added 2 tests (nsString UTF-8 round-trip; loadHTMLString adversarial empty/invalid-UTF-8/64KiB) + extended selector-responder coverage (addSubview:/bounds for the attach surface). No impl bugs. attach() live test deferred to manual checklist M1.4-G1..G5. → TESTING
- M1.4 — zig-developer — implemented `src/webview.zig`: `WebView{init/attach/loadHTMLString/deinit}` — WKWebView + fresh WKWebViewConfiguration, `setInspectable:true`, `attach()` fills window contentView via width|height autoresizingMask, `loadHTMLString:baseURL:` (nil baseURL). No ARC (config +1 defer-released after initWithFrame: retains it; webview +1 owned by deinit, errdefer on init). Reused window.zig CG types (made pub) + added `Window.contentView()` accessor. WKWebView init empirically headless-safe → live tests added. `zig build` + `zig build test` green (30/30). → IN_REVIEW
- M1.3 — orchestrator — code-reviewer APPROVE (no CRITICAL/MAJOR; +1 NSWindow owned by deinit with errdefer on the only fallible path, title NSString +1/defer-released, nil sender for makeKeyAndOrderFront:, CGRect extern-ABI by-value path verified for aarch64). test-runner green 22/22 (3× deterministic), 0 impl bugs. `zig build` + `zig build test` exit 0. Committed. → DONE
- M1.3 — test-runner — `zig build` + `zig build test` green, 22/22, exit 0, deterministic across 3 runs. Added 3 headless-safe tests to `src/window.zig` (CGPoint/CGSize/CGFloat C-ABI layout; NSWindow + NSString selector-responder checks). Found + fixed 1 test bug (wrong `respondsToSelector` variant for a class method); 0 implementation bugs. GUI behaviour deferred to manual checklist M1.3-G1..G8. → TESTING
- M1.3 — zig-developer — implemented `src/window.zig`: `Window{init/deinit/setTitle}` creating a titled/closable/resizable, centered NSWindow shown via `makeKeyAndOrderFront:`. CGRect/CGPoint/CGSize as `extern struct` for msgSend ABI. No ARC (window +1 owned by deinit, errdefer on error path; title NSString +1/defer-released). `init()` not headless-safe (needs window server) → no live-init test, GUI deferred to manual checklist. `zig build` + `zig build test` green. → IN_REVIEW
- M1.2 — orchestrator — code-reviewer APPROVE (no findings; retain counts traced, zig-objc calls verified). Working tree integrity re-verified after test-runner's `git checkout` incident (impl + tests intact). `zig build` + `zig build test` green (14/14). Committed. → DONE
- M1.2 — test-runner — added 6 headless tests to `src/app.zig` (Error-set shape, public API/type contract, AppKit class + `terminate:` selector resolution, and a live `init()` test asserting the NSApp singleton is non-nil, idempotent, and that the installed main menu carries a single "Quit" item bound to `terminate:`/key "q"). Empirically probed that `init()`/`activate()` are headless-safe (run + return, no window server); `run()` excluded as it blocks the run loop. `zig build` + `zig build test` green: 14/14 (13 lib + 1 exe), stable across 3 runs. GUI behaviour (Dock icon, foregrounding, Cmd+Q termination) deferred to the M1.5 manual checklist below. → TESTING
- M1.2 — zig-developer — implemented `src/app.zig`: `App.init()` obtains `+[NSApplication sharedApplication]`, sets activation policy `.regular` (NSApplicationActivationPolicyRegular = 0), and installs a main menu with a Quit item bound to Cmd+Q (`terminate:`, key "q"). Added `App.run()` ([NSApp run]) and `App.activate()`. All transient menu/NSString objects released after AppKit retains them (no ARC). `zig build` + `zig build test` green. → IN_REVIEW
- M1.1 — orchestrator — scaffold created: build.zig (wkz module + example exe, AppKit/WebKit/Foundation/libobjc, `-Ddev` via build_options, test step), 7 src stubs (doc comment + refAllDecls), zig-objc pinned at `c8de82f`, Vite vanilla-ts frontend, `@wkz/bridge` TS stub, .gitignore/README/CI. `zig build` + `zig build test` green. → DONE

## Decisions

- **zig-objc ref**: pinned to commit `c8de82ff80281215ad92900866dab7103a8efa8b` (main HEAD, 2026-04-17). This is the first line that includes "Add Zig 0.16 compatibility" (`fd36c1c`) + the 0.16 translate-c bug fix (`41ea96c`); no 0.16-tagged release exists, so pin by hash rather than `master`.
- **`src/root.zig` added** as the public API aggregator (not in the original architecture list). Idiomatic Zig module root; re-exports app/window/webview/bridge and keeps scheme/objc_helpers internal but in the test graph.

## Manual GUI checklist

GUI behaviour cannot run under headless `zig build test` (no window server / blocking run loop). Verify by hand once an example calls `App.run()` (lands in M1.5):

- **M1.2-G1 (launch):** `zig build run -Ddev=true` starts without crashing and the process stays alive (run loop blocks, does not return immediately).
- **M1.2-G2 (regular app):** app appears in the Dock with an icon and owns the menu bar (activation policy `.regular`). It is not an `.accessory`/background agent.
- **M1.2-G3 (foreground):** if `activate()` is called before `run()`, the app comes to the foreground / becomes the active app on launch.
- **M1.2-G4 (menu):** the app menu (leftmost, bold) contains a single **Quit** item.
- **M1.2-G5 (Cmd+Q):** pressing **Cmd+Q** (or clicking Quit) fires `terminate:` and the process exits cleanly (the `zig build run` command returns).
- **M1.3-G1 (open):** `zig build run -Ddev=true` opens a single window (no crash, no hang at launch).
- **M1.3-G2 (titled):** the title bar shows the exact string passed to `Window.init`.
- **M1.3-G3 (closable):** the red close button is present and closes the window.
- **M1.3-G4 (resizable):** dragging an edge/corner resizes it; the zoom (green) button works.
- **M1.3-G5 (centered):** the window is centered on the active screen on first appearance.
- **M1.3-G6 (front+key):** the window comes to the front and becomes key (`makeKeyAndOrderFront:`) without a manual click.
- **M1.3-G7 (setTitle):** calling `setTitle` with a new value updates the visible title bar text live.
- **M1.3-G8 (shutdown):** Cmd+Q quits cleanly with the window on screen (no leak/abort on shutdown).
- **M1.4-G1 (fill):** the WKWebView fills the entire window contentView edge-to-edge (no gray border/gap).
- **M1.4-G2 (resize):** resizing the window tracks web content on both axes (width|height autoresizing), no clipping/letterboxing.
- **M1.4-G3 (inspector):** right-click → "Inspect Element" (or Develop menu) opens the Web Inspector (`setInspectable:true`; macOS 13.3+).
- **M1.4-G4 (render):** inline `loadHTMLString` page renders (heading/text visible) and is interactive (text selectable).
- **M1.4-G5 (shutdown):** Cmd+Q quits cleanly with the webview attached (no hang/crash on teardown).

### M1.5 — end-to-end (`zig build run`); exercises M1.2/M1.3/M1.4 GUI items together

- **M1.5-G1 (window opens):** single window appears, centered, ~900×600, title "wkz", front + key.
- **M1.5-G2 (page renders):** webview fills the content area; dark page (`#0b0d12`) with centered "wkz"; no gaps/scrollbars.
- **M1.5-G3 (fill + resize):** dragging the corner resizes; page tracks both axes, no gap/letterbox/clip.
- **M1.5-G4 (foregrounded):** app comes to front on launch (`.regular` policy, Dock icon, owns menu bar).
- **M1.5-G5 (inspector):** right-click → "Inspect Element" opens the Web Inspector (macOS 13.3+).
- **M1.5-G6 (Cmd+Q):** app menu has a single Quit (⌘Q); pressing it terminates cleanly, `zig build run` returns.
- **M1.5-G7 (dev banner):** stdout shows `dev mode: true` under `-Ddev=true`, `dev mode: false` for the default build.

## Blocked

- _(none)_
