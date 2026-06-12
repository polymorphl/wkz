import { invoke } from "./index.js";

export interface UpdateInfo {
  version: string;
  notes: string;
}

/**
 * Typed wrappers for the Zig updater bridge handlers.
 *
 * Push events from Zig use window.__wkz_event — subscribe with wkz.on():
 *   on("update.available", (payload) => { ... })  // payload: UpdateInfo
 *   on("update.progress", (payload) => { ... })   // payload: { percent: number }
 *   on("update.ready",    (payload) => { ... })   // payload: {}
 *   on("update.error",    (payload) => { ... })   // payload: { code: string, message: string }
 */
export const updater = {
  /** Check for an update. Returns UpdateInfo if a newer version is available, null if up to date. */
  check: (): Promise<UpdateInfo | null> =>
    invoke<UpdateInfo | null>("updater.check", {}),

  /** Download the pending update. Emits update.progress events. */
  download: (): Promise<void> => invoke<void>("updater.download", {}),

  /** Atomically install and restart. Never resolves on success (process is replaced). */
  install: (): Promise<void> => invoke<void>("updater.install", {}),
};
