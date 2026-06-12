# examples/fs

Demonstrates the `wkz.fs` bridge module: open a native file picker (NSOpenPanel),
read files as text or base64, and write text — all via the typed JS↔Zig bridge.

## Run

```sh
cd examples/fs
zig build run
```

Requires Zig 0.16.x. Run from `examples/fs/` so the local `wkz` path dependency resolves.

## What it shows

| Button | Bridge calls | Result |
|--------|-------------|--------|
| Open & Read Text | `fs.openFile` → `fs.readText` | NSOpenPanel picks a file; UTF-8 content shown in panel |
| Open & Read Binary | `fs.openFile` → `fs.readBinary` | File read as base64; first 512 chars shown |
| Write /tmp/wkz-demo.txt | `fs.writeText` | Writes a fixed string; verify with `cat /tmp/wkz-demo.txt` |

## Size limit

Files larger than **10 MiB** resolve `null` — the handler logs a warning and the UI
shows an error message.

## Zig module

```zig
var fs = wkz.fs.Fs.init(allocator);
try fs.registerBridgeHandlers(&bridge);
// Registers: fs.openFile, fs.readText, fs.readBinary, fs.writeText
```
