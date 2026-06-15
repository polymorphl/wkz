# examples/dragdrop

Demonstrates the wkz drag-and-drop API: drop files from Finder onto the window and see their paths emitted as a `dragdrop.filesDropped` bridge event.

## Prerequisites

- macOS (arm64 or x86_64)
- Zig 0.16.x (`zig version` must report `0.16.`)

## Run

```sh
cd examples/dragdrop
zig build run
```

Opens a 720×500 window with a drop zone. Try:

- **Drag one or more files** from Finder onto the window — paths appear in the list.
- **Cmd+Q** — quits.

## Build only

```sh
zig build
# binary at zig-out/bin/dragdrop_example
```

## How it works

`src/main.zig` wires `DragDrop` between the window and the bridge:

```
App.init()           — boots NSApplication
Window.init()        — creates a titled, resizable NSWindow
WebView.init()       — creates a WKWebView filling the window
Bridge.init()        — sets up the JS↔Zig message channel
DragDrop.init()      — inserts a transparent NSView overlay above the WKWebView
                       registers it for NSFilenamesPboardType drags
app.run()            — enters the AppKit run loop
```

When files are dropped, the overlay's `performDragOperation:` IMP:
1. Reads paths from `NSPasteboard` via `propertyListForType:`
2. Serialises them as JSON
3. Calls `bridge.evaluate("__wkz_event({type:'dragdrop.filesDropped',payload:{paths:[...]}})")` 

The frontend listens via `globalThis.__wkz_event` (or `on("dragdrop.filesDropped", handler)` from `@wkz/bridge` in TS projects).

### Why a transparent overlay?

The WKWebView owns its content view and handles its own drag events. Rather than subclassing WKWebView, `DragDrop` inserts a sibling `NSView` above it with `hitTest:` overridden to return `nil` — mouse clicks fall through to the WKWebView; only the AppKit drag machinery routes file drops to the overlay.

wkz is consumed as a path dependency (`../..` in `build.zig.zon`).
