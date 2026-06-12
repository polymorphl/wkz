# examples/updater

Demonstrates the wkz auto-updater end-to-end: a window with an embedded HTML+JS UI that drives `updater.check`, `updater.download`, and `updater.install` over the JS↔Zig bridge.

## Prerequisites

- macOS (arm64 or x86_64)
- Zig 0.16.x (`zig version` must report `0.16.`)

## Run

```sh
cd examples/updater
zig build run
```

**Must be run from `examples/updater/`** — the updater resolves `manifest.json` relative to the current working directory.

Opens a 700×480 window with three buttons. Quit with **Cmd+Q**.

## Build only

```sh
zig build
# binary at zig-out/bin/updater
```

## What it demonstrates

| Button | Bridge call | What happens |
|---|---|---|
| Check for Updates | `updater.check` | Reads `manifest.json`, compares versions, emits `update.available` event if newer |
| Download | `updater.download` | Fetches the binary URL, verifies SHA-256, emits progress events |
| Install & Restart | `updater.install` | Atomically replaces the running binary and re-execs the process |

## Manifest

`manifest.json` contains a sample update manifest (version `0.2.0`). The app's hardcoded `current_version` is `0.1.0`, so **Check for Updates always finds an update**.

The `url` fields point to `example.com` — **Download will fail at runtime** by design. To test the full flow, replace the URLs with a real binary and update the `sha256` field accordingly.

### Manifest format

```json
{
  "version": "1.0.0",
  "pub_date": "2026-06-12T12:00:00Z",
  "notes": "Release notes shown in the UI.",
  "platforms": {
    "darwin-aarch64": {
      "url": "https://example.com/releases/1.0.0/myapp-aarch64",
      "sha256": "<64-char lowercase hex SHA-256 of the binary>",
      "signature": "<base64 ed25519 signature, or null>"
    },
    "darwin-x86_64": {
      "url": "https://example.com/releases/1.0.0/myapp-x86_64",
      "sha256": "<64-char lowercase hex SHA-256 of the binary>",
      "signature": null
    }
  }
}
```

## Signature verification

Disabled in this demo (`public_key = null` in `main.zig`). To enable, generate an ed25519 keypair and set `public_key` to the 32-byte public key:

```zig
var updater = wkz.updater.Updater.init(allocator, .{
    .manifest_source = .{ .file = manifest_path },
    .current_version = "0.1.0",
    .public_key = [32]u8{ 0x... },
});
```

Sign the binary with the private key and set `"signature"` in the manifest to the base64-encoded 64-byte ed25519 signature.

## URL manifest source

To fetch the manifest over HTTP instead of from a local file, use `.url`:

```zig
.manifest_source = .{ .url = "https://example.com/latest/manifest.json" },
```

`nsDataDownload` uses `NSData dataWithContentsOfURL:` (synchronous, main thread).

## How it works

```
Bridge.init + attach()           — registers the JS message handler
Updater.init                     — configures manifest source and current version
registerBridgeHandlers()         — wires updater.check / .download / .install
webview.loadHTMLString(UI_HTML)  — loads src/ui.html (compiled in via @embedFile)
```

`src/ui.html` contains a self-contained vanilla JS implementation of the bridge protocol (`__resolve`, `__wkz_event`, `invoke()`, `on()`) — no npm, no build step.
