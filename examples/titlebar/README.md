# examples/titlebar

Demonstrates the two non-default `TitlebarStyle` variants: `.transparent` and `.hidden`. Opens two cascaded windows so the difference is immediately visible side by side.

## Prerequisites

- macOS (arm64 or x86_64)
- Zig 0.16.x (`zig version` must report `0.16.`)

## Run

```sh
cd examples/titlebar
zig build run
```

Opens two 700×500 windows:

| Window | Style | Effect |
|--------|-------|--------|
| Left — "Transparent titlebar" | `.transparent` | Titlebar is transparent; window title visible; web content extends under it (28 pt top padding in CSS). |
| Right — "Hidden titlebar" | `.hidden` | Titlebar and title hidden; web content fills 100% of the window; traffic lights float over the UI (28 pt top padding in CSS). |

Quit with **Cmd+Q**.

## Build only

```sh
zig build
# binary at zig-out/bin/titlebar
```

## How it works

`src/main.zig` passes a `WindowConfig` with a `titlebar` field to `Window.init`:

```
Window.init(.{ .width = 700, .height = 500, .title = "…", .titlebar = .transparent })
Window.init(.{ .width = 700, .height = 500, .title = "…", .titlebar = .hidden })
```

### TitlebarStyle variants

| Variant | `NSWindowStyleMask` addition | Extra AppKit calls |
|---------|-----------------------------|--------------------|
| `.default` | none | none |
| `.transparent` | `FullSizeContentView` | `setTitlebarAppearsTransparent: true` |
| `.hidden` | `FullSizeContentView` | `setTitlebarAppearsTransparent: true` + `setTitleVisibility: hidden` |

### CSS safe area

Both styles push web content under the traffic-lights area (~28 pt). The frontend handles it:

```css
body { padding-top: 28px; }
/* or, for viewport-fit=cover: */
body { padding-top: env(safe-area-inset-top, 28px); }
```

wkz does not inject the inset via the bridge in V1.

wkz is consumed as a path dependency (`../..` in `build.zig.zon`).
