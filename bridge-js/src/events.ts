declare global {
  function __wkz_event(event: { type: string; payload?: unknown }): void;
}

type EventHandler = (payload: unknown) => void;

const listeners = new Map<string, Set<EventHandler>>();

globalThis.__wkz_event = function (event: {
  type: string;
  payload?: unknown;
}): void {
  const handlers = listeners.get(event.type);
  if (!handlers) return;
  for (const handler of handlers) {
    try {
      handler(event.payload ?? {});
    } catch (err) {
      console.error(`@wkz/bridge: event handler for "${event.type}" threw:`, err);
    }
  }
};

/**
 * Subscribe to a Zig-pushed event by type.
 * Returns an unsubscribe function — call it to remove the handler.
 *
 * @example
 *   const unsub = on("update.available", (payload) => console.log(payload));
 *   // later:
 *   unsub();
 */
export function on(
  event: string,
  handler: EventHandler,
): () => void {
  let set = listeners.get(event);
  if (!set) {
    set = new Set();
    listeners.set(event, set);
  }
  set.add(handler);
  return () => {
    set!.delete(handler);
    if (set!.size === 0) listeners.delete(event);
  };
}

// HMR: clean up on module hot-reload to prevent duplicate listeners
const _hot = (
  import.meta as unknown as { hot?: { dispose(cb: () => void): void } }
).hot;
if (_hot) {
  _hot.dispose(() => {
    listeners.clear();
    delete (globalThis as Record<string, unknown>)["__wkz_event"];
  });
}
