// @wkz/bridge — typed client for the wkz JS<->Zig bridge.
//
// Calls flow JS -> Zig over the WKScriptMessageHandler registered as "bridge".
// Each call carries a monotonically incrementing integer id; Zig replies by
// evaluating `__resolve(id, result)` in the page context. This module is the
// typed wrapper around that convention.
//
// Side effects on import:
//   - Installs `globalThis.__resolve` for Zig to call back into.
//   - Registers an HMR dispose handler (if import.meta.hot is available) that
//     rejects pending promises and removes the global before the new module
//     version reinstalls it.

// ---------------------------------------------------------------------------
// TypeScript augmentations
// ---------------------------------------------------------------------------

declare global {
  // Installed by this module; called by Zig via evaluateJavaScript.
  // `result` is the raw JS value passed by Zig — a string, number, or object
  // depending on the JS expression Zig evaluates.
  function __resolve(id: number, result: unknown): void;
  function __wkz_event(event: { type: string; payload?: unknown }): void;

  interface Window {
    webkit?: {
      messageHandlers?: {
        bridge?: {
          postMessage(msg: string): void;
        };
      };
    };
  }
}

// ---------------------------------------------------------------------------
// Module state
// ---------------------------------------------------------------------------

type PendingCall = {
  resolve: (value: unknown) => void;
  reject: (reason: unknown) => void;
};

const pendingCalls = new Map<number, PendingCall>();

// id=0 is a valid correlation id (Zig side treats null/absent id as
// fire-and-forget, 0 as a real id). We start at 0 so that the first call
// gets id=0, matching the Zig test suite expectation. The counter wraps at
// Number.MAX_SAFE_INTEGER to avoid precision loss; in practice a single
// session will never reach that.
let nextId = 0;

// ---------------------------------------------------------------------------
// __resolve global (Zig -> JS reply path)
// ---------------------------------------------------------------------------

globalThis.__resolve = function __resolve(id: number, result: unknown): void {
  const pending = pendingCalls.get(id);
  if (pending === undefined) {
    console.warn(`@wkz/bridge: __resolve received unknown id=${id} (already resolved, rejected, or never sent)`);
    return;
  }

  pendingCalls.delete(id);
  pending.resolve(result);
};

// ---------------------------------------------------------------------------
// HMR — idempotent teardown on hot reload
// ---------------------------------------------------------------------------

// `import.meta.hot` is typed by vite/client when compiled inside the frontend;
// when bridge-js is compiled standalone (no vite types), we cast through unknown.
const _hot = (import.meta as unknown as { hot?: { dispose(cb: () => void): void } }).hot;
if (_hot) {
  _hot.dispose(() => {
    // Pending promises can never resolve — the Zig context that would have
    // called __resolve is gone. Reject them so callers don't leak.
    for (const [, pending] of pendingCalls) {
      pending.reject(new Error('@wkz/bridge: HMR reload, call abandoned'));
    }
    pendingCalls.clear();

    // Remove the global so the incoming fresh module version can reinstall it
    // without a "duplicate __resolve" warning or stale closure.
    delete (globalThis as Record<string, unknown>)['__resolve'];
  });
}

// ---------------------------------------------------------------------------
// invoke<T> — JS -> Zig RPC
// ---------------------------------------------------------------------------

/**
 * Invoke a registered Zig handler by name and await its typed result.
 *
 * @typeParam T - the expected shape of the handler's result.
 * @param method - the handler name registered on the Zig side via `registerHandler`.
 * @param params - JSON-serializable arguments passed to the handler.
 * @returns a promise resolving to `T` when Zig calls `bridge.resolve(id, result)`.
 *
 * Notes:
 * - Fire-and-forget: if the method has no id correlation on the Zig side, the
 *   promise stays pending indefinitely (no built-in timeout in M3.3).
 * - Rejects immediately when called outside a WKWebView context (webkit bridge
 *   not available).
 */
export function invoke<T>(method: string, params?: unknown): Promise<T> {
  const messageBridge = window.webkit?.messageHandlers?.bridge;
  if (!messageBridge) {
    return Promise.reject(
      new Error('@wkz/bridge: invoke() called outside a WKWebView — window.webkit.messageHandlers.bridge is not available'),
    );
  }

  const id = nextId;
  // Advance and wrap to stay within safe integer range.
  nextId = nextId < Number.MAX_SAFE_INTEGER ? nextId + 1 : 0;

  return new Promise<T>((resolve, reject) => {
    pendingCalls.set(id, {
      resolve: resolve as (value: unknown) => void,
      reject,
    });

    try {
      messageBridge.postMessage(JSON.stringify({ method, params, id }));
    } catch (err) {
      // postMessage itself threw (shouldn't happen in practice, but guard it).
      pendingCalls.delete(id);
      reject(new Error(`@wkz/bridge: postMessage failed for method="${method}": ${String(err)}`));
    }
  });
}
