// @wkz/bridge — typed client for the wkz JS<->Zig bridge.
//
// Calls flow JS -> Zig over the WKScriptMessageHandler registered as "bridge".
// Each call carries a correlation id; Zig replies by evaluating
// `__wkz_resolve(id, result)` in the page. This module is the typed wrapper
// around that convention.
//
// M1.1 scaffold: signature only. Implementation lands in M3.3 (request/response
// correlation + HMR-idempotent setup via import.meta.hot.dispose).

/**
 * Invoke a registered Zig handler by name and await its typed result.
 *
 * @typeParam T - the expected shape of the handler's result.
 * @param method - the handler name registered on the Zig side.
 * @param params - JSON-serializable arguments for the handler.
 * @returns a promise resolving to the handler's result.
 */
export async function invoke<T>(method: string, params?: unknown): Promise<T> {
  void method;
  void params;
  throw new Error("@wkz/bridge: invoke() not implemented yet (M3.3)");
}
