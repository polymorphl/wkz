# examples/events

Demonstrates the wkz window-events API: when the window gains or loses keyboard focus, a `window.focused` or `window.blurred` event is pushed from Zig to the web UI.

## Prerequisites

- macOS (arm64 or x86_64)
- Zig 0.16.x (`zig version` must report `0.16.`)

## Run

```sh
cd examples/events
zig build run
```

Opens a 640×400 window with a large focus-state badge and an event log. Try:

- **Click another app** — badge turns red: `BLURRED`
- **Click back** — badge turns green: `FOCUSED`
- **Cmd+Q** — quits

## Build only

```sh
zig build
# binary at zig-out/bin/events_example
```

## How it works

```
App.init()              — boots NSApplication
Window.init()           — creates a titled, resizable NSWindow
WebView.init()          — creates a WKWebView filling the window
Bridge.init()           — sets up the JS↔Zig message channel
WindowEvents.init()     — registers WkzWindowObserver with NSNotificationCenter
app.run()               — enters the AppKit run loop
```

### NSNotificationCenter observer approach

`WindowEvents` registers a custom `WkzWindowObserver` NSObject subclass with
`NSNotificationCenter.defaultCenter` for two notifications scoped to the
specific window object:

- `NSWindowDidBecomeKeyNotification` → `window.focused`
- `NSWindowDidResignKeyNotification` → `window.blurred`

When either fires on the main thread, the `handleNotification:` IMP recovers a
heap-allocated `*WindowEvents` context pointer from the observer's ivar, maps
the notification name to an event type string, and calls:

```
bridge.evaluate("__wkz_event({\"type\":\"window.focused\"})")
```

The frontend's `globalThis.__wkz_event` function receives the parsed object and
updates the UI.

`WindowEvents.deinit` calls `removeObserver:` before releasing the ObjC object,
so no notification can fire after teardown.

### Why not resize events here?

AppKit resize notifications (`NSWindowDidResizeNotification`) are available via
the same mechanism, but the web frontend already tracks its own layout via the
browser's `ResizeObserver` API — no Zig plumbing is needed for that. Only
events that originate outside the DOM (focus/blur from the OS window manager)
benefit from the NSNotificationCenter approach.

wkz is consumed as a path dependency (`../..` in `build.zig.zon`).
