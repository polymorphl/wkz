# examples/statusitem

Demonstrates the `wkz.statusitem` bridge module: native NSStatusItem menu-bar
status items (icon/title) via the typed JS↔Zig bridge, with click events firing
back to JS.

## Run

```sh
cd examples/statusitem
zig build run
```

Requires Zig 0.16.x. Run from `examples/statusitem/` so the local `wkz` path
dependency resolves.

## What it shows

| Button | Bridge call | Effect |
|--------|------------|--------|
| Set Title | `statusitem.set { title }` | Creates or updates the menu-bar item text |
| Set Icon (circle.fill) | `statusitem.set { icon: 'circle.fill' }` | Sets an SF Symbol icon (macOS 12+) |
| Remove | `statusitem.remove {}` | Removes the item from the menu bar |

Click the status item in the menu bar — the click counter increments via
`window.__wkz_event({ type: 'statusitem.click' })`.

## Zig module

```zig
// StatusItem uses bridge.context — one per bridge instance.
// Do NOT combine with Fs or Updater on the same bridge.
var status_item = wkz.statusitem.StatusItem.init(allocator, &bridge);
defer status_item.deinit();
try status_item.registerBridgeHandlers(&bridge);
// Registers: statusitem.set, statusitem.remove
```

## JS API

```js
// Create or update the status item
await invoke('statusitem.set', {
  title: '▶ 2:34',    // optional — text shown in menu bar
  icon: 'circle.fill', // optional — SF Symbol name (macOS 12+)
});
// returns: null

// Remove the status item
await invoke('statusitem.remove', {});
// returns: null

// Receive click events
window.__wkz_event = function (e) {
  if (e.type === 'statusitem.click') { /* handle */ }
};
```
