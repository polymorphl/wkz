# examples/alert

Demonstrates the `wkz.alert` bridge module: native NSAlert modal dialogs via the typed JS↔Zig bridge.

## Run

```sh
cd examples/alert
zig build run
```

Requires Zig 0.16.x. Run from `examples/alert/` so the local `wkz` path dependency resolves.

## What it shows

| Button | Bridge call | Alert style |
|--------|------------|-------------|
| Show Alert | `alert.show { title }` | Warning (default) — single OK button |
| Delete File… | `alert.show { title, message, style: 'critical', buttons: ['Cancel', 'Delete'] }` | Critical (red ⊗ icon) |
| Check for Update | `alert.show { title, message, style: 'informational', buttons: ['Later', 'Install Now'] }` | Informational |

Each button click shows the alert and displays the returned button label below.

## Zig module

```zig
// No struct — registerAlertHandler does not set bridge.context,
// so it is safe to combine with Fs or Updater on the same bridge.
try wkz.alert.registerAlertHandler(&bridge);
// Registers: alert.show
```

## JS API

```js
const result = await invoke('alert.show', {
  title: 'Delete file?',          // required
  message: 'Cannot be undone.',   // optional
  style: 'critical',              // 'warning' | 'informational' | 'critical'
  buttons: ['Cancel', 'Delete'],  // optional, default ['OK'], max 3
});
// result: { button: 'Delete' } | null
```
