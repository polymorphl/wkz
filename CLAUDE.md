# wkz

A pure-Zig macOS desktop shell library: AppKit + WKWebView driven directly through the Objective-C runtime (via mitchellh/zig-objc), with a typed bidirectional JS↔Zig bridge. Frontend is framework-agnostic (Vite in dev, embedded assets in prod). No Swift, no compiled Objective-C, no C glue. Think "the wry layer of Tauri, for macOS, in Zig".

> Status: not production ready. Pre-v0.1, scaffolding outward.

## Toolchain rules

- **Zig 0.16.x, pinned.** `zig version` must report `0.16.`. Do not adapt code to another version; if the toolchain is wrong, stop and fix the toolchain.
- **NEVER write Zig std API calls from memory.** Training data is stale for `std.Io`, `ArrayList`, and the build APIs — these changed in 0.16. Verify every signature before use:
  - Prefer the **zig-docs MCP server** if available.
  - Otherwise grep the local std source: `/opt/homebrew/Cellar/zig/<ver>/lib/zig/std` (find it with `find /opt/homebrew/Cellar/zig -name Build.zig -path '*lib*'`).
  - Quote what was verified (file + signature) in the implementation report.
- **Only dependency is zig-objc** (module name `objc`), pinned by commit hash in `build.zig.zon`. Its API is verified against Zig 0.16. Adding any other dependency is a MAJOR review finding.

## Architecture map

| Path | Responsibility |
|------|----------------|
| `src/main.zig` | Runnable example; what `zig build run` launches. |
| `src/app.zig` | NSApplication bootstrap: activation policy, menu (Cmd+Q), run loop. |
| `src/window.zig` | NSWindow: titled/closable/resizable, centered, makeKeyAndOrderFront. |
| `src/webview.zig` | WKWebView filling contentView, configuration, content loading. |
| `src/bridge.zig` | Typed JS↔Zig bridge: script message handler, dispatch, RPC correlation. |
| `src/scheme.zig` | `app://` WKURLSchemeHandler serving embedded `dist/` assets in prod. |
| `src/objc_helpers.zig` | Objective-C runtime glue (class creation, selectors, encodings). |
| `src/root.zig` | Public API surface — re-exports the supported types/functions. |
| `frontend/` | Framework-agnostic web UI (Vite, vanilla-ts). |
| `bridge-js/` | Typed TS client (`@wkz/bridge`): `invoke<T>(method, params)`. |

## Hard rules

1. **Main thread only.** All AppKit/WebKit calls happen on the main thread; the run loop owns it. No background-thread UI access.
2. **No ARC.** Every `alloc`/`new`/`copy`/`retain` is paired with a `release` via `defer`/`errdefer`, including on error paths. Ownership is documented in doc comments. Unpaired release on any path is a CRITICAL bug.
3. **No Objective-C blocks.** Pass `nil` completion handlers; deliver responses back through the JS→Zig channel instead.
4. **Allocator-first.** Every allocating function takes an `Allocator`. Tests use `std.testing.allocator` (it detects leaks).
5. **Dev/prod is the `-Ddev` build option, never a runtime env branch.** `-Ddev=true` → `loadRequest http://localhost:5173`. Release (default) → `app://` scheme handler + `@embedFile`'d assets.

## Build commands

```sh
zig build                 # build the library + example
zig build run -Ddev=true  # run against the Vite dev server
zig build test            # run all tests (headless)
zig build dev             # dev mode: Vite + app in one command (recommended)
# or manually:
cd frontend && bun run dev # start the Vite dev server (port 5173)
```

## Orchestration protocol

The **main session is the orchestrator and NEVER writes implementation code.** It coordinates subagents and owns commits.

1. **Session start:** read `TASK.md` and summarize current state before acting.
2. **Per task, dispatch in order:** `zig-developer` (implement) → `code-reviewer` (mandatory) → `test-runner`.
3. **`TASK.md` is the single source of truth.** Statuses: `TODO → IN_PROGRESS → IN_REVIEW → TESTING → DONE | BLOCKED(reason)`. Each agent run appends one log line.
4. **CRITICAL/MAJOR review findings go back to `zig-developer` verbatim.** Max 2 fix cycles, then escalate to the human.
5. **Architectural questions are surfaced to the human with options**, never decided silently.
6. **The orchestrator commits, agents don't.** One commit per `DONE` task, in [Conventional Commits](https://www.conventionalcommits.org/) format: `<type>[(scope)]: <imperative summary>` (e.g. `feat: add NSApplication bootstrap`, `chore: scaffold project`). Reference the milestone in the body as `Milestone: M<n>`.
7. **Parallelize only independent tasks.**
