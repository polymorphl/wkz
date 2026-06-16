# examples/shell

Demonstrates the wkz shell API: open URLs in the default system application (browser, mail client, etc.) wired through the JS↔Zig bridge.

## Prerequisites

- macOS (arm64 or x86_64)
- Zig 0.16.x (`zig version` must report `0.16.`)

## Run

```sh
cd examples/shell
zig build run
```

Opens a 640×440 window with two panels:

- **Open URL** — type any URL and click to open it in the default browser.
- **Quick Links** — one-click buttons for common URLs.

**Cmd+Q** quits.

## Build only

```sh
zig build
# binary at zig-out/bin/shell_example
```

## How it works

`src/main.zig` registers the shell bridge handler and loads the embedded UI:

```
App.init()                     — boots NSApplication
Window.init()                  — creates a titled, resizable NSWindow
WebView.init()                 — creates a WKWebView filling the window
Bridge.init()                  — sets up the JS↔Zig message channel
shell.registerHandlers(&bridge) — registers shell.open
app.run()                      — enters the AppKit run loop
```

When the page calls `shell.open(url)`:
1. Zig builds a NUL-terminated copy of the URL string.
2. `[NSString stringWithUTF8String:]` wraps it as an autoreleased NSString.
3. `[NSURL URLWithString:]` parses it into an autoreleased NSURL (nil if malformed).
4. `[[NSWorkspace sharedWorkspace] openURL:]` dispatches it to the registered scheme handler.
5. Resolves `true` to JS if the NSURL was valid, `false` on param or parse errors.

The `openURL:` return value is intentionally ignored — macOS launches applications
asynchronously and the method returns before the handler app is running.

`NSWorkspace.sharedWorkspace` is a process-singleton — it is never released.
`NSString` and `NSURL` results from class methods are autoreleased — never released manually.

wkz is consumed as a path dependency (`../..` in `build.zig.zon`).
