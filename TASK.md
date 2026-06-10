# wkz — Task Tracker

Single source of truth for work. Statuses: `TODO → IN_PROGRESS → IN_REVIEW → TESTING → DONE | BLOCKED(reason)`.

## Current focus

**M3.2 — `registerHandler` comptime API + request/response correlation.** (M3.1 DONE.)

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
| 2.1 | `objc_helpers.zig` runtime class creation (allocateClassPair + method registration), unit-tested | DONE |
| 2.2 | ScriptMessageHandler class implementing `userContentController:didReceiveScriptMessage:`, registered as `"bridge"` | DONE |
| 2.3 | NSDictionary → Zig extraction, std.json parse, dispatch table | DONE |
| 2.4 | Malformed input logs, never crashes | DONE |

## M3 — Typed RPC + Vite

| ID | Task | Status |
|----|------|--------|
| 3.1 | `evaluateJavaScript` (nil handler) + `__resolve(id, result)` convention | DONE |
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

- M3.1 — orchestrator — code-reviewer APPROVE (0 findings; ARC clean — NSString +1/defer-released in evaluate, buildResolveJS slice defer-freed in resolve on all paths including nil-webview early-return; webview BORROWED not released in deinit; main.zig untouched — doesn't call Bridge.init yet; allocPrintSentinel return type [:0]u8 verified). test-runner 87/87 ×3. 4 new tests: buildResolveJS double-quote raw-inject contract, minInt(i64), OOM via FailingAllocator, buildResolveJS API surface. Manual checklist M3.1-G1..G4 authored. Committed. → DONE
- M2.4 — orchestrator — 74/74 tests pass (73 lib + 1 example). adversarial battery: oversized body pre-parse guard, deeply-nested iterative-parse no stack-overflow, i64-overflow number_string, invalid UTF-8, hostile shape matrix (14 cases), duplicate keys, void-boundary swallow. logRejected emits stage/len/prefix only, never full payload. `zig build test --summary all` exit 0. Committed. → DONE
- M2.3 — orchestrator — code-reviewer APPROVE_WITH_MINORS (no CRITICAL/MAJOR; parse-arena freed on all paths, params borrow call-scoped + documented, static-literal map keys, no panic on malformed, std.json/StringHashMap signatures spot-checked real). 2 MINORs sent back to zig-developer (fix cycle 1): null-`UTF8String` crash guard added; dead `_ = root.get("id")` removed. MINOR#3 (body size-cap) → M2.4. Re-verified green by orchestrator + test-runner 65/65 (seed-independent ×6), 0 impl bugs. Committed. → DONE
- M2.3 — test-runner — suite 65/65 (64 lib + 1 example), exit 0, seed-independent across 6 runs. Added 5 headless tests under testing.allocator (unknown-method arena-free — the MAJOR-risk leak path; nested object/array params intact; non-object params pass-through unvalidated; multi-handler routing discriminates by key; populated-map deinit frees N entries). No impl bugs. Residual: `UTF8String`-null defensive guard + live-JS round-trip remain manual (M2.2-G/M2.3 checklist). → TESTING
- M2.3 — zig-developer — implemented JSON-string dispatch in `src/bridge.zig` per wire-format decision: body NSString → `UTF8String` → `std.json.parseFromSlice` → method/params/(id seam) → `std.StringHashMap(Handler)` lookup → invoke. `Bridge.init(allocator, ucc)` owns the map; `addHandler(method, fn)` runtime registration; pure `dispatchSlice([]const u8)` core (NSString-free, headless-testable); `dispatchMessage` does the ObjC leg. `DispatchError{InvalidMessage,MissingMethod,UnknownMethod}||Allocator.Error`. No ARC (UTF8String borrowed/not freed, Parsed.deinit on all paths, map freed in deinit, handler +1 still released). Fix cycle 1 applied 2 review MINORs (null-UTF8String guard; dead-id removal). `zig build` + `zig build test` green (60→65/65). → IN_REVIEW
- M2.2 — orchestrator — code-reviewer APPROVE_WITH_MINORS (no CRITICAL/MAJOR; all 4 lifetime/ABI risks verified safe — raw `*Bridge` in id ivar is no-retain under MRC per zig-objc object.zig, init/attach address-stability sound, deinit deregisters before release, IMP C-ABI/derived-encoding correct). MINOR#1 (controller-identity claim only doc-verified) closed by test-runner; MINOR#2 (OnMessage seam) accepted clean; MINOR#3 (Bridge allocator-free) deferred to M2.3. test-runner 53/53 (3× stable), 0 impl bugs. `zig build` + `zig build test` exit 0. Committed. → DONE
- M2.2 — test-runner — 53/53 (52 lib + 1 example), 3× deterministic, exit 0. Closed reviewer MINOR#1: added controller pointer-identity test (webview.zig) proving `userContentController()` returns a stable controller AND that independent `configuration` copies share the one controller instance (load-bearing routing precondition). Added handler negative-selector control + IMP nil-ivar-guard test (bridge.zig). 0 impl bugs. Residual: live JS `postMessage` routing → manual checklist M2.2-G2. → TESTING
- M2.2 — zig-developer — implemented `src/bridge.zig`: `Bridge{init/attach/handleMessage/deinit}`. Open-coded handler class `WkzScriptMessageHandler` (getClass guard → allocateClassPair(NSObject) → addIvar("wkz_ctx") → addMethod(userContentController:didReceiveScriptMessage:, imp) → registerClassPair) per the human decision. IMP (C-ABI, derived encoding) recovers `*Bridge` from the raw-pointer ivar (no-ARC-safe: object_setIvar/getIvar are raw stores under MRC, context borrowed not retained) and routes `body` to a swappable `OnMessage` callback (M2.3 seam, defaults to logMessage). init-by-value + attach(*Bridge) split for stable address; deinit removeScriptMessageHandlerForName: before release. Added `WebView.userContentController()` accessor. Handler +1 owned by Bridge (controller also retains), name NSString +1/defer-released. `zig build` + `zig build test` green (50/50). → IN_REVIEW
- M2.1 — orchestrator — code-reviewer APPROVE (zero findings; no-ARC correct — registered classes process-lived not refcounted, test instances defer-released, NSString +0 not over-released; encodings derived from fn types via zig-objc comptimeEncode not hand-written; IMPs C-ABI with c.id/c.SEL first; nil allocateClassPair → ClassRegistrationFailed, no deref; idempotency guard correct). test-runner 41/41 (3× stable), 0 impl bugs. `zig build` + `zig build test` exit 0. Committed. → DONE
- M2.1 — test-runner — added 4 live tests (mixed-width/type arg marshalling i64/i32/bool; negative selector-response; addIvar false after-register; addIvar false on duplicate). Suite 41/41 (40 lib + 1 example), stable across 3 runs, exit 0. Noted `ClassRegistrationFailed` runtime branch is unreachable via the `getClass` idempotency guard (design observation, not a bug); `addMethod` false is `assert`-guarded so not observable. Zero implementation bugs. Fully headless — no GUI checklist. → TESTING
- M2.1 — zig-developer — implemented `src/objc_helpers.zig`: `defineClass(name, super, methods) Error!Class` (idempotent via getClass guard; allocateClassPair → addMethod → registerClassPair), `addIvar(cls, name) bool` (id-typed M2.2 context slot), `method(name, imp)` spec builder preserving imp's concrete fn type, `Error{ClassRegistrationFailed}`. Uses zig-objc wrappers; encodings derived (not hand-written); IMPs plain C-ABI Zig fns. Per-instance M2.2 context decided = id ivar (over associated-object). 5 tests (3 live create→send→assert + ivar round-trip, 2 compile-time). `zig build` + `zig build test` green (37/37). → IN_REVIEW
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
- **M2.3 wire format** (human decision, 2026-06-10): JS sends a **JSON string** — `bridge.postMessage(JSON.stringify({method, params, id}))`. Zig reads the body NSString via `UTF8String` → `std.json.parseFromSlice`. NOT a native NSDictionary walk. `Bridge` gains an `Allocator` (via `init`) for JSON parsing, satisfying the allocator-first rule. Cleanest seam for M3 typed RPC; bridge-js client owns the stringify.
- **M2.2 handler context attachment** (human decision, 2026-06-10): M2.2 **open-codes** the class-creation sequence (`allocateClassPair` → `addIvar("ctx")` → `addMethod` → `registerClassPair`) directly, rather than extending `defineClass` with an `ivars` param or using `objc_setAssociatedObject`. The Zig bridge context pointer is stored in an `id`-typed ivar read back in the IMP via `object_getInstanceVariable`. `defineClass` (M2.1) stays as-is for the ivar-free case.
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

### M2.2 — JS→Zig bridge handler (live JS round-trip; needs run loop + loaded page, wired in M2.4/M3)

- **M2.2-G1 (handler reachable):** in the loaded page's console, `window.webkit.messageHandlers.bridge` is defined (an object), not `undefined`.
- **M2.2-G2 (IMP fires + routing):** `window.webkit.messageHandlers.bridge.postMessage("hello")` logs `wkz bridge: received message ...` on stdout — proves the IMP fired and recovered context on the controller the live webview actually routes through (the leg the headless identity test cannot prove).
- **M2.2-G3 (body shapes):** posting a string / number / object each logs the matching ObjC body class (`__NSCFString` / `__NSCFNumber` / `__NSDictionary…`), confirming body reachable for M2.3 extraction.
- **M2.2-G4 (ordering):** handler installed (`Bridge.attach`) before page load; a page that posts on load is received (no message lost).
- **M2.2-G5 (teardown):** Cmd+Q after exercising the bridge quits cleanly (handler deregistered, no abort).

### M3.1 — evaluateJavaScript + resolve (needs live WKWebView + run loop + loaded page)

- **M3.1-G1 (evaluate fires):** Call `bridge.evaluate("window.__testSentinel = 42")` then `bridge.evaluate("window.webkit.messageHandlers.bridge.postMessage(JSON.stringify({method:'check',params:window.__testSentinel}))")`. Confirm the `"check"` Zig handler receives `params` = integer `42`.
- **M3.1-G2 (resolve round-trip):** From JS, post `{method:"echo",id:5,params:"hello"}`. Zig handler calls `bridge.resolve(5, "\"hello\"")`. Confirm `__resolve(5, "hello")` executes in JS (log or promise resolution).
- **M3.1-G3 (evaluate syntax error):** Call `bridge.evaluate("this is not JS ///")`. Process must not crash (WebKit drops JS error silently with nil handler).
- **M3.1-G4 (resolve post-navigation):** After loading a new page, call `bridge.resolve(1, "true")`. Must not crash.

## Blocked

- _(none)_
