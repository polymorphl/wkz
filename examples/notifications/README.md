# examples/notifications

Demonstrates the wkz notifications API: request macOS notification permission and deliver local notifications, wired through the JS↔Zig bridge.

## Prerequisites

- macOS (arm64 or x86_64)
- Zig 0.16.x (`zig version` must report `0.16.`)

## Run

```sh
cd examples/notifications
zig build run
```

Opens a 560×480 window. Suggested flow:
1. Click **Request Permission** — registers the app with macOS notifications (provisional first, then upgrade dialog for banners).
2. Click **Send Notification** — fills in title/body and delivers a local notification. If the app is in the foreground the banner appears immediately; in the background it appears as a standard system notification.

**Cmd+Q** quits.

## Build only

```sh
zig build
# binary at zig-out/bin/notifications_example
```

## How it works

`src/main.zig` registers the notification bridge handlers and loads the embedded UI:

```
App.init()                              — boots NSApplication
Window.init()                           — creates a titled, resizable NSWindow
WebView.init()                          — creates a WKWebView filling the window
Bridge.init()                           — sets up the JS↔Zig message channel
notifications.registerHandlers(&bridge) — registers notifications.requestPermission + notifications.send
app.run()                               — enters the AppKit run loop
```

**Why the `.app` bundle?** `UNUserNotificationCenter` requires the process to have a `bundleProxyForCurrentProcess` — only available when launched via Launch Services. `zig build run` builds a `.app` bundle and launches it with `open -W` so macOS sets this up correctly.

When the page calls `notifications.requestPermission`:
1. Zig calls `[UNUserNotificationCenter currentNotificationCenter]`.
2. A `WkzUNDelegate` is registered as the center's delegate so foreground notifications can display banners (see below).
3. `requestAuthorizationWithOptions:completionHandler:` is called twice with a `nil` completion handler:
   - **Step 1 — provisional** (options = badge | sound | alert | provisional = 71): silently registers the app with the notification system on first run, no dialog. On subsequent runs this is a no-op.
   - **Step 2 — upgrade** (options = badge | sound | alert = 7): once provisional is established, this triggers the macOS "allow notifications?" upgrade dialog.
4. Resolves `true` to JS immediately (fire-and-forget).

When the page calls `notifications.send({title, body, id?})`:
1. Zig extracts `title` and `body` from the JSON object params.
2. A `UNMutableNotificationContent` is created (`+new`, released via `defer`) with title and body set via autoreleased NSStrings.
3. A `UNNotificationRequest` is built with the provided `id` (or an auto-generated `wkz-notif-N` identifier) and a `nil` trigger (deliver immediately).
4. `addNotificationRequest:withCompletionHandler:nil` schedules the notification.
5. Resolves `true` to JS.

**Foreground banners — `WkzUNDelegate`:** without a delegate, macOS suppresses notification banners when the app is in the foreground. `notifications.zig` registers a custom `WkzUNDelegate` ObjC class (inheriting `NSObject`, conforming to `UNUserNotificationCenterDelegate`) that implements `userNotificationCenter:willPresentNotification:withCompletionHandler:`. The IMP reads the completion-handler block's invoke function pointer (at offset 16 of the block struct, per the Darwin block ABI) and calls it with options = banner | list | sound (= 14), requesting full banner display.

**ARC notes:**
- `currentNotificationCenter` returns a singleton — never released.
- `stringWithUTF8String:` NSStrings and `requestWithIdentifier:content:trigger:` are autoreleased — never released manually.
- `UNMutableNotificationContent +new` is `+1` owned, released via `defer`.
- `WkzUNDelegate +new` is `+1` and intentionally process-lived (never released): the delegate must outlive the center singleton.

> **Note:** sandboxed apps additionally require the `com.apple.security.app-sandbox` and `com.apple.usernotifications` entitlements. This example runs unsandboxed (ad-hoc codesigning only).

wkz is consumed as a path dependency (`../..` in `build.zig.zon`).
