# examples/clipboard

Demonstrates the wkz clipboard API: read text from the system clipboard and write text to it, all wired through the JS↔Zig bridge.

## Prerequisites

- macOS (arm64 or x86_64)
- Zig 0.16.x (`zig version` must report `0.16.`)

## Run

```sh
cd examples/clipboard
zig build run
```

Opens a 640×440 window with two panels:

- **Read Clipboard** — click to read the current clipboard text into the page.
- **Write to Clipboard** — type text and click to copy it to the system clipboard.

**Cmd+Q** quits.

## Build only

```sh
zig build
# binary at zig-out/bin/clipboard_example
```

## How it works

`src/main.zig` registers the clipboard bridge handlers and loads the embedded UI:

```
App.init()                          — boots NSApplication
Window.init()                       — creates a titled, resizable NSWindow
WebView.init()                      — creates a WKWebView filling the window
Bridge.init()                       — sets up the JS↔Zig message channel
registerClipboardHandlers(&bridge)  — registers clipboard.readText + clipboard.writeText
app.run()                           — enters the AppKit run loop
```

When the page calls `clipboard.readText`:
1. Zig calls `[NSPasteboard generalPasteboard]` to obtain the singleton pasteboard.
2. `[pb stringForType:"public.utf8-plain-text"]` returns the text (or nil if none).
3. The result is serialised as `{"text":"..."}` and resolved back to JS.

When the page calls `clipboard.writeText`:
1. Zig builds an NSString from the JS-supplied text.
2. `[pb clearContents]` clears the pasteboard.
3. `[pb setString:ns_text forType:"public.utf8-plain-text"]` writes the text.

`NSPasteboard.generalPasteboard` is a process-singleton — it is never released.
Strings from `stringWithUTF8String:` are autoreleased — never released manually.

wkz is consumed as a path dependency (`../..` in `build.zig.zon`).
