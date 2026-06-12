//! Typed bidirectional JS <-> Zig bridge.
//!
//! Responsibility: the public bridge API. Registers a `WKScriptMessageHandler`
//! named "bridge" on a webview's `WKUserContentController`, so JS
//! `window.webkit.messageHandlers.bridge.postMessage(...)` reaches a Zig IMP.
//! From there it will parse incoming messages (treated as HOSTILE input: shape
//! and size validated before std.json parse), dispatch to typed handlers, and
//! reply via evaluateJavaScript using an id-correlated `__resolve(id, result)`
//! convention. Every allocating function takes an Allocator.
//!
//! M2.2 scope: the handler class exists, is registered, the IMP fires, the Zig
//! context pointer round-trips through an ivar, and the message `body` is
//! reachable in the IMP and handed to a `on_message` callback.
//!
//! M2.3 scope: the default `on_message` now extracts the body NSString to UTF-8,
//! runs it through `std.json.parseFromSlice` (the wire format is a JSON string —
//! `postMessage(JSON.stringify({ method, params, id }))`, NOT a native
//! NSDictionary), reads `method` / `params` / optional `id`, and routes `method`
//! through a runtime dispatch table (`std.StringHashMap`) to the registered Zig
//! handler, passing the parsed `params`. The comptime-typed `registerHandler` +
//! request/response (`__resolve`) correlation is M3.1/M3.2 — see the seam notes
//! on `dispatchSlice`.
//!
//! M2.4 scope: the contract "malformed input logs, never crashes" is now
//! enforced end-to-end on the message path. ANY input arriving from JS — empty,
//! whitespace, invalid UTF-8, valid-JSON-but-not-an-object, missing/null/
//! wrong-typed `method`, an oversized body, or one nested thousands of levels
//! deep — is rejected as a clean `DispatchError` from the pure `dispatchSlice`
//! core and then LOGGED + SWALLOWED at the void `dispatchMessage` boundary, so
//! no Zig error ever escapes into the C-ABI IMP. A pre-parse size guard
//! (`max_body_len`) rejects oversized bodies BEFORE the parser sees them; the
//! parser itself is iterative and heap-bounded, so deep nesting yields an error
//! (folded into `InvalidMessage`), never a stack overflow or panic. Every
//! failure logs its stage (extraction / size / parse / missing-method /
//! unknown-method) at `warn`, with the body byte length and a short prefix
//! only — never the full (hostile, possibly huge) payload.
//!
//! Main thread only. No ARC: see the ownership notes on `Bridge`.

const std = @import("std");
const objc = @import("objc");

const c = objc.c;

/// Scoped logger for the bridge. `std.log.scoped(comptime scope: @EnumLiteral()) type`
/// (std/log.zig:137) returns a namespace with `.warn`/`.info`/`.err`/`.debug`
/// (each `(comptime format, args) void`, std/log.zig:153-176). Scoping to
/// `.wkz_bridge` lets a host app filter/route bridge diagnostics distinctly.
const log = std.log.scoped(.wkz_bridge);

/// Maximum accepted size, in bytes, of one incoming message body BEFORE it is
/// handed to `std.json.parseFromSlice`. Bodies larger than this are rejected
/// (logged + dropped) without ever touching the parser.
///
/// Why a pre-parse cap (M2.4 hardening): the JSON parse-to-`Value` path is
/// iterative but its working set is `O(nesting depth)` of heap memory — the
/// scanner pushes each `[`/`{` onto a heap `BitStack` (json/Scanner.zig:328-334,
/// memory note line 3) and the dynamic decoder grows a heap `Array` stack
/// (json/dynamic.zig:79-119). std.json's own `default_max_value_len` (4 MiB,
/// json/Scanner.zig:1571) only bounds a SINGLE string/number token, not the
/// whole document or its depth — and `parseFromSlice` defaults `max_value_len`
/// to the input length anyway (json/static.zig:32-34,134-138), so it is no guard
/// at all here. A hostile page can `postMessage` an arbitrarily large / deeply
/// nested body; without a cap that is unbounded attacker-controlled memory
/// pressure (a DoS on a trust-but-bounded LOCAL channel). 1 MiB is far above any
/// legitimate RPC payload (method name + small params) yet cheaply bounds the
/// worst case. We reject by byte length before allocating any parse arena.
pub const max_body_len: usize = 1 * 1024 * 1024;

/// How many leading body bytes a rejection log line may quote. The body is
/// hostile and potentially huge or sensitive, so failure logs NEVER include the
/// whole payload — only its byte length plus this short prefix (for triage). See
/// `logRejected`.
const log_body_prefix_len: usize = 32;

/// Process-unique name for the runtime `WKScriptMessageHandler` subclass. A
/// registered Objective-C class lives for the whole process (it is not
/// reference-counted), so one definition per process is correct, not a leak.
const handler_class_name: [:0]const u8 = "WkzScriptMessageHandler";

/// Name of the `id`-typed instance variable on the handler class that stores the
/// borrowed `*Bridge` context pointer (see `Bridge` ownership notes).
const ctx_ivar_name: [:0]const u8 = "wkz_ctx";

/// The JS message-handler name. JS posts via
/// `window.webkit.messageHandlers.bridge.postMessage(...)`.
const message_handler_name: [:0]const u8 = "bridge";

/// Errors surfaced while wiring the bridge into a webview.
pub const Error = error{
    /// A required Foundation class could not be looked up in the runtime, or the
    /// runtime failed to allocate the handler class pair. Both are fatal.
    ClassNotFound,
} || std.mem.Allocator.Error;

/// Errors surfaced while turning one incoming UTF-8 JSON message into a handler
/// invocation. These describe HOSTILE input (M2.4 will formalize "log, never
/// crash"); for M2.3 they propagate cleanly out of `dispatchSlice` and are
/// logged at the `on_message` boundary rather than panicking.
pub const DispatchError = error{
    /// The body byte length exceeded `max_body_len`. Rejected BEFORE parse — no
    /// arena is allocated — so an oversized hostile body never reaches the JSON
    /// parser (the pre-parse memory-pressure guard, M2.4).
    MessageTooLarge,
    /// The body bytes did not parse as JSON, or the top-level value was not a
    /// JSON object. Either way there is no message to dispatch. This also covers
    /// invalid UTF-8, numbers that overflow the parser's limits, and input so
    /// deeply nested it exhausts the allocator (`OutOfMemory` from the parser is
    /// folded in here): all surface as one clean error, never a panic.
    InvalidMessage,
    /// The parsed object had no `method` string (missing, or not a string).
    MissingMethod,
    /// The `method` string did not match any registered handler.
    UnknownMethod,
} || std.mem.Allocator.Error;

/// A registered Zig handler for one `method`. Receives the owning `*Bridge`,
/// the parsed `params` JSON value (`.null` when the message carried no `params`),
/// and an optional `id` for request/response correlation.
///
/// The `params` `Value` borrows the JSON parse arena that owns it; it is valid
/// only for the duration of this call and must NOT be retained past return (copy
/// out anything needed longer).
///
/// If `id` is non-null, the handler may call `bridge.resolve(id.?, result)` to
/// reply to the JS caller. When `id` is null the message is fire-and-forget
/// (JS did not provide a correlation id) — calling `resolve` in that case is
/// undefined at the application level (there is no waiting caller).
pub const Handler = *const fn (bridge: *Bridge, params: std.json.Value, id: ?i64) void;

/// The runtime dispatch table: `method` name -> Zig `Handler`.
///
/// Key memory is managed by the caller (per `std.StringHashMap`'s contract — it
/// does NOT copy keys). wkz registers methods with static `[]const u8` string
/// literals whose lifetime is the program, so no key copy or key free is needed;
/// `deinit` only frees the map's own backing storage. If dynamic method names
/// were ever registered, the caller would have to own those key bytes.
const DispatchTable = std.StringHashMap(Handler);

/// A reply path the IMP hands the raw message `body` to. The body is a borrowed,
/// autoreleased Objective-C object (the wire format makes it an NSString) owned
/// by WebKit for the duration of the call — the callback must NOT release it and
/// must NOT retain it past the call without taking its own +1. The default
/// callback (`dispatchMessage`) is the JSON-parse + dispatch path; tests swap in
/// their own probe.
pub const OnMessage = *const fn (bridge: *Bridge, body: objc.Object) void;

/// Default `on_message`: extract the body NSString to UTF-8 bytes, then run the
/// pure parse+dispatch core (`dispatchSlice`). Per the wire format the body is a
/// JSON string, so `-[NSString UTF8String]` yields the document bytes directly.
///
/// No ARC: `-[NSString UTF8String]` returns a C string that is internally owned
/// by the NSString (autoreleased storage) — we must NOT free it. We only read it
/// for the duration of this call (`dispatchSlice` copies nothing out of it past
/// the parse), so no copy into Bridge-allocated memory is required here; the
/// JSON parser copies the bytes it keeps into its own arena.
///
/// `dispatchSlice` returns a `DispatchError` on hostile/malformed input. Because
/// `OnMessage` is `void`, we log and swallow it here (M2.4 formalizes the
/// logging policy); it never panics.
fn dispatchMessage(bridge: *Bridge, body: objc.Object) void {
    // STAGE: extraction (null body). Apple delivers a body for every message,
    // but it is hostile input — guard rather than assume.
    if (body.value == null) {
        log.warn("dropped message: null body (stage=extraction)", .{});
        return;
    }

    // Per the wire format the body is an NSString. -UTF8String returns a
    // NUL-terminated C string whose lifetime is the NSString's (borrowed, not
    // owned by us): never freed here. Apple documents it as returning NULL on
    // encoding failure, and the body is hostile input — so receive it as an
    // optional and guard the null before span(). msgSend with a `?[*:0]const u8`
    // return type routes through zig-objc's optional-pointer case
    // (msg_send.zig:112-115 / unwrapType msg_send.zig:239-242) and yields the
    // raw result directly (it is not an Object), so a plain null check applies.
    //
    // STAGE: extraction (un-decodable body).
    const utf8 = body.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse {
        log.warn("dropped message: un-decodable body (stage=extraction)", .{});
        return;
    };
    const bytes = std.mem.span(utf8);

    // `dispatchSlice` is the pure core: it RETURNS a `DispatchError` (tests
    // assert the kinds precisely). The void IMP boundary lives here — so this is
    // where every error kind is mapped to a useful, redacted log line and then
    // SWALLOWED. No error may escape this function: the ObjC IMP
    // (`impUserContentControllerDidReceive`) calls `handleMessage` -> here, all
    // `void`; a Zig error propagating into the C-ABI IMP would be undefined, so
    // the `catch` below is the hard guarantee that it cannot.
    bridge.dispatchSlice(bytes) catch |err| logRejected(err, bytes);
}

/// Log a rejected message (the void-boundary swallow point). Never logs the
/// whole body: the body is hostile input and may be huge or sensitive, so we
/// emit the failure STAGE/kind, the body byte length, and at most
/// `log_body_prefix_len` leading bytes for triage. The prefix is printed with
/// `{s}` over a clamped slice — non-printable bytes are passed through to the
/// log sink as-is (bounded), never expanded; the load-bearing diagnostic is the
/// error kind + length, not the content.
fn logRejected(err: DispatchError, bytes: []const u8) void {
    const n = @min(bytes.len, log_body_prefix_len);
    const prefix = bytes[0..n];
    switch (err) {
        DispatchError.MessageTooLarge => log.warn(
            "dropped message: body too large (stage=size, len={d}, cap={d})",
            .{ bytes.len, max_body_len },
        ),
        DispatchError.InvalidMessage => log.warn(
            "dropped message: invalid/unparseable JSON (stage=parse, len={d}, prefix=\"{s}\")",
            .{ bytes.len, prefix },
        ),
        DispatchError.MissingMethod => log.warn(
            "dropped message: missing/non-string method (stage=missing-method, len={d}, prefix=\"{s}\")",
            .{ bytes.len, prefix },
        ),
        DispatchError.UnknownMethod => log.warn(
            "dropped message: unknown method (stage=unknown-method, len={d}, prefix=\"{s}\")",
            .{ bytes.len, prefix },
        ),
        DispatchError.OutOfMemory => log.warn(
            "dropped message: out of memory while dispatching (stage=parse, len={d})",
            .{bytes.len},
        ),
    }
}

/// The JS->Zig bridge attached to one webview.
///
/// Ownership (no ARC):
///   * `handler` is a `+1` instance of the runtime `WKScriptMessageHandler`
///     subclass, alloc/init'd by `init` and released by `deinit`.
///     `addScriptMessageHandler:name:` makes the `WKUserContentController` retain
///     the handler too, so it survives for as long as either reference is held;
///     `Bridge` keeps its own `+1` so the handler (and thus the live IMP path)
///     stays valid for the bridge's lifetime, and balances it in `deinit`.
///   * The handler's `wkz_ctx` ivar holds a BORROWED `*Bridge` pointer. It is a
///     raw pointer write via `object_setIvar` (zig-objc `setInstanceVariable`),
///     which under MRC performs NO retain/release — it is a plain machine-word
///     store into the `id`-typed slot. The `Bridge` is NOT an Objective-C object
///     and must never be retained/released through that slot; the pointer is
///     owned by Zig (the caller keeps the `Bridge` alive for as long as the
///     webview can deliver messages). Storing a non-`id` pointer in an `id` ivar
///     is safe precisely because there is no ARC here to apply object semantics
///     to the slot, and wkz fully owns both the get and the set. `deinit`
///     deregisters the handler so no message can fire against a dangling
///     pointer after the `Bridge` is gone.
///   * `webview` is BORROWED (not +1, not retained). The caller's `WebView`
///     struct owns the `+1` WKWebView reference; `Bridge` holds a non-owning
///     reference to it solely to call `-[WKWebView evaluateJavaScript:completionHandler:]`.
///     The caller must ensure the `WKWebView` outlives the `Bridge`. `deinit`
///     does NOT release `webview`.
///
/// Lifetime ordering: `Bridge` must outlive any content loaded into the webview
/// that can post to `bridge`. Install the bridge (`init`) BEFORE loading such
/// content (`addScriptMessageHandler:name:` only affects content loaded after
/// the call). Tear down (`deinit`) only once the webview will deliver no further
/// messages.
pub const Bridge = struct {
    /// The owned `+1` handler instance. Released by `deinit`.
    handler: objc.Object,

    /// The `WKUserContentController` the handler is registered on. Borrowed
    /// (owned by the webview/configuration); used by `deinit` to deregister.
    ucc: objc.Object,

    /// The `WKWebView` this bridge evaluates JavaScript on. BORROWED: not +1,
    /// not retained. Owned by the caller's `WebView` struct; must outlive `Bridge`.
    webview: objc.Object,

    /// Where the IMP routes each incoming message body. Defaults to
    /// `dispatchMessage` (extract + parse + dispatch); tests may swap a probe.
    on_message: OnMessage,

    /// Allocator used for JSON parsing (the parse arena), the dispatch table's
    /// backing storage, and per-call JS string building in `resolve`. Borrowed
    /// from the caller via `init`; `Bridge` does not own it.
    allocator: std.mem.Allocator,

    /// Generic context pointer for modules that register bridge handlers and
    /// need to recover their own state at dispatch time (e.g. updater).
    context: ?*anyopaque = null,

    /// Runtime method -> handler table. Heap-owned by this `Bridge` (its backing
    /// storage is freed by `deinit`). Keys are not copied (static literals).
    dispatch: DispatchTable,

    /// Register a `WKScriptMessageHandler` named "bridge" on `ucc` (obtain it
    /// from `WebView.userContentController()`), wiring this `Bridge` as the
    /// context the IMP recovers.
    ///
    /// Must be called on the main thread. The handler class is created once per
    /// process (idempotent). On success the returned `Bridge` owns a `+1` handler
    /// reference that `deinit` releases; on the error path nothing is leaked.
    ///
    /// Must be followed by `attach()` before any content is loaded; forgetting
    /// `attach` will silently drop all messages in release builds.
    ///
    /// IMPORTANT: the IMP recovers the context by the *address* stored in the
    /// handler's ivar. `init` does NOT write that ivar — it cannot know the final
    /// address of a by-value return, which the caller will move into its own
    /// storage. The caller MUST place the returned `Bridge` at a stable address
    /// (a long-lived local or field that outlives the webview) and then call
    /// `attach(self: *Bridge)` exactly once. See `attach`.
    ///
    /// `allocator` is borrowed (not owned) and used for JSON parsing, the
    /// dispatch table's backing storage, and JS string building in `resolve`; the
    /// map is built here and freed by `deinit`. On the error path the +1 handler
    /// is released (errdefer) so nothing leaks.
    ///
    /// `webview` is BORROWED (not +1, not retained). Pass the raw `ns_webview`
    /// field (or `WebView.ns_webview`) of the live `WebView`. The caller is
    /// responsible for ensuring the WKWebView outlives this `Bridge`.
    pub fn init(allocator: std.mem.Allocator, ucc: objc.Object, webview: objc.Object) Error!Bridge {
        const handler_class = try handlerClass();

        // +1 handler instance owned by this Bridge (released in deinit). If a
        // later step in init fails, this errdefer balances it.
        const handler = handler_class.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "init", .{});
        errdefer handler.msgSend(void, "release", .{});

        // StringHashMap.init (hash_map.zig:170) takes only the allocator; the
        // map allocates lazily, so this cannot fail, but keep it before the
        // return so any future fallible setup is covered by the errdefer above.
        const dispatch = DispatchTable.init(allocator);

        return .{
            .handler = handler,
            .ucc = ucc,
            .webview = webview,
            .on_message = dispatchMessage,
            .allocator = allocator,
            .dispatch = dispatch,
        };
    }

    /// Register a runtime `Handler` for `method`. Last registration for a given
    /// `method` wins (overwrites). `method` is borrowed: per `std.StringHashMap`
    /// the key bytes are NOT copied, so the caller must keep them alive for the
    /// `Bridge`'s lifetime — wkz registers static string literals, which satisfy
    /// this trivially. Returns `Allocator.Error` if the map cannot grow.
    ///
    /// This is the M2.3 runtime registration seam. `registerHandler` (M3.2) is
    /// the only public registration API; `addHandler` is private.
    fn addHandler(self: *Bridge, method: []const u8, handler: Handler) std.mem.Allocator.Error!void {
        // HashMap.put (hash_map.zig:322): put(self, key, value) !void. Does not
        // copy the key (StringHashMap keys are caller-managed).
        try self.dispatch.put(method, handler);
    }

    /// Public API: register a handler for a comptime-known `method` name.
    ///
    /// This is the **only public registration API**. `addHandler` is private.
    ///
    /// The `comptime method` parameter enforces that the method string is a
    /// static literal known at compile time, which satisfies the
    /// `std.StringHashMap` "keys are not copied" contract by construction — it
    /// is impossible for a caller to pass a dynamically allocated slice whose
    /// lifetime is shorter than the `Bridge`. This is the only difference from
    /// the internal `addHandler`; the runtime behaviour is identical.
    ///
    /// The `handler` parameter is also comptime so callers get a compile-time
    /// error if the function signature does not match `Handler`
    /// (`fn(*Bridge, std.json.Value, ?i64) void`).
    ///
    /// For M3.2 the handler signature is the same as `Handler` — comptime
    /// derivation of typed param/return structs is deferred to M4+.
    ///
    /// Returns `Allocator.Error` if the dispatch table cannot grow.
    pub fn registerHandler(
        self: *Bridge,
        comptime method: []const u8,
        comptime handler: fn (bridge: *Bridge, params: std.json.Value, id: ?i64) void,
    ) std.mem.Allocator.Error!void {
        try self.addHandler(method, handler);
    }

    /// Evaluate a JavaScript expression in the webview. The `js` argument is a
    /// NUL-terminated UTF-8 JS source string (already fully formed). The call is
    /// fire-and-forget: the completion handler is `nil` (no ObjC block, per hard
    /// rule #3). Any JS-side syntax error is silently discarded by WebKit.
    ///
    /// No ARC: the transient NSString is +1 from `nsString`/`stringWithUTF8String:
    /// retain`, and released via `defer` on the one return path. Must be called on
    /// the main thread (WebKit requirement).
    pub fn evaluate(self: *Bridge, js: [:0]const u8) void {
        const NSString = objc.getClass("NSString") orelse {
            log.warn("bridge: NSString class not found; evaluate is a no-op", .{});
            return;
        };
        const ns_js = nsString(NSString, js);
        defer ns_js.msgSend(void, "release", .{});
        // evaluateJavaScript:completionHandler: (WKWebView). The second arg is a
        // block (id); we pass null (nil) per the no-ObjC-blocks rule. The selector
        // takes two explicit args beyond self/cmd.
        self.webview.msgSend(
            void,
            "evaluateJavaScript:completionHandler:",
            .{ ns_js, @as(?*anyopaque, null) },
        );
    }

    /// Build the JS expression string `__resolve(<id>, <result>)` using
    /// `allocator`. The caller owns the returned sentinel slice and must free it.
    ///
    /// `result` is a raw JS expression (not a JSON-quoted string) — the caller
    /// is responsible for any quoting/encoding. Example: `buildResolveJS(7, "\"hi\"", …)`
    /// produces `__resolve(7, "hi")`.
    ///
    /// Pure Zig — no ObjC calls. Testable headlessly. `resolve` calls this, then
    /// `evaluate`, then frees the slice.
    ///
    /// Verified: `std.fmt.allocPrintSentinel` (fmt.zig:639):
    ///   `pub fn allocPrintSentinel(gpa, comptime fmt, args, comptime sentinel) Allocator.Error![:sentinel]u8`
    pub fn buildResolveJS(
        id: i64,
        result: []const u8,
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error![:0]u8 {
        return std.fmt.allocPrintSentinel(
            allocator,
            "__resolve({d}, {s})",
            .{ id, result },
            0,
        );
    }

    /// Deliver a reply to the JS caller identified by `id`. Builds the string
    /// `__resolve(<id>, <result>)` and calls `evaluate` with it. This is the
    /// Zig→JS reply path: when JS sends `{ method, params, id }`, Zig calls
    /// `resolve(id, json_result)` to answer it.
    ///
    /// `result` is a raw JS expression string — not quoted. The caller is
    /// responsible for encoding: e.g. `resolve(7, "\"hello\"")` evaluates
    /// `__resolve(7, "hello")` in the webview.
    ///
    /// Memory: `buildResolveJS` allocates a sentinel slice from `self.allocator`;
    /// it is freed with `defer` after `evaluate` copies its content into an
    /// NSString. No allocation survives this call. Must be called on the main
    /// thread (WebKit requirement).
    ///
    /// Returns `Allocator.Error` only if the JS string cannot be allocated.
    pub fn resolve(self: *Bridge, id: i64, result: []const u8) std.mem.Allocator.Error!void {
        const js = try buildResolveJS(id, result, self.allocator);
        defer self.allocator.free(js);
        self.evaluate(js);
    }

    /// Pure parse + dispatch core: take a UTF-8 JSON document, parse it, read
    /// `method` / `params` / optional `id`, look `method` up in the dispatch
    /// table, and invoke the registered handler with `params`.
    ///
    /// Factored to take a `[]const u8` (not an NSString) so it is unit-testable
    /// headlessly with crafted JSON slices, independent of the ObjC IMP path.
    /// `dispatchMessage` does the NSString->slice extraction and calls this.
    ///
    /// No ARC concern (pure Zig). Memory: `std.json.parseFromSlice` returns a
    /// `Parsed(Value)` owning an arena; `defer parsed.deinit()` frees it on every
    /// path (json/static.zig:56-66). The `params` `Value` handed to the handler
    /// borrows that arena and is only valid during the handler call.
    ///
    /// M3.1/M3.2 seam: `id` is not read in M2.3 (no reply path yet); the
    /// request/response correlation will later read it here to carry it into the
    /// `__resolve(id, result)` reply without reworking this parse path.
    pub fn dispatchSlice(self: *Bridge, bytes: []const u8) DispatchError!void {
        // Pre-parse size guard (M2.4): reject oversized bodies by byte length
        // BEFORE allocating any parse arena, so an unbounded attacker-controlled
        // slice never reaches std.json (see `max_body_len` for the DoS rationale
        // and why std.json's own limits do not cover this). This early return
        // has allocated nothing, so there is nothing to free — no leak.
        if (bytes.len > max_body_len) return DispatchError.MessageTooLarge;

        // parseFromSlice (json/static.zig:73): (T, allocator, s, options)
        // !Parsed(T). Any parse failure — syntax error, invalid UTF-8, a number
        // longer than the parser's max_value_len, or OutOfMemory from a deeply
        // nested document (the scanner's depth stack is heap-backed and the
        // decode loop is ITERATIVE, json/Scanner.zig:328-334 + json/dynamic.zig:
        // 79-119, so deep nesting exhausts the allocator, never the C stack /
        // never panics) — is folded into InvalidMessage. The parser returns an
        // error in every case; it does not panic on any input shape.
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            bytes,
            .{},
        ) catch return DispatchError.InvalidMessage;
        // Parsed(T).deinit (json/static.zig:61) frees the arena on every path.
        defer parsed.deinit();

        // Top-level must be a JSON object: { method, params, id }.
        const root = switch (parsed.value) {
            .object => |obj| obj,
            else => return DispatchError.InvalidMessage,
        };

        // `method` (required, string). ObjectMap is a StringArrayHashMap(Value);
        // .get (array_hash_map.zig:613) returns ?Value.
        const method: []const u8 = switch (root.get("method") orelse return DispatchError.MissingMethod) {
            .string => |s| s,
            else => return DispatchError.MissingMethod,
        };

        // `id` (optional): present and integer → extract as i64 for RPC
        // correlation; absent, null, or wrong type → null (fire-and-forget).
        // ObjectMap.get (array_hash_map.zig:613) returns ?Value.
        const id: ?i64 = if (root.get("id")) |id_val| switch (id_val) {
            .integer => |n| n,
            else => null,
        } else null;

        // `params` (optional, arbitrary JSON): default to .null when absent so
        // the handler always receives a well-formed Value.
        const params: std.json.Value = root.get("params") orelse .null;

        // Look the method up in the dispatch table. get (hash_map.zig:367)
        // returns ?Handler.
        const handler = self.dispatch.get(method) orelse return DispatchError.UnknownMethod;

        handler(self, params, id);
    }

    /// Finish wiring the bridge now that it lives at its final, stable address:
    /// store `self` into the handler's context ivar and register the handler on
    /// the user content controller under the name "bridge".
    ///
    /// Split from `init` because the IMP recovers the context by the *address* of
    /// the `Bridge`; that address is only stable once the caller has placed the
    /// `Bridge` in its final storage (a by-value return from `init` would move
    /// it). Call exactly once, on the main thread, before loading content that
    /// posts to `bridge`.
    ///
    /// The borrowed `*self` is stored raw (no retain) in the `id` ivar — see the
    /// `Bridge` ownership notes for why that is no-ARC-safe.
    pub fn attach(self: *Bridge) Error!void {
        const NSString = objc.getClass("NSString") orelse return Error.ClassNotFound;

        // Raw pointer store into the id ivar: object_setIvar performs no retain
        // under MRC, so the borrowed *Bridge is not given object semantics.
        self.handler.setInstanceVariable(
            ctx_ivar_name,
            .{ .value = @ptrCast(self) },
        );

        // +1 NSString for the handler name; the controller copies it, so we
        // release our reference after the add (on every path).
        const name = nsString(NSString, message_handler_name);
        defer name.msgSend(void, "release", .{});

        // The controller retains the handler. Our own +1 (released by deinit)
        // keeps the IMP path valid for the Bridge's lifetime regardless.
        self.ucc.msgSend(
            void,
            "addScriptMessageHandler:name:",
            .{ self.handler, name },
        );
    }

    /// Route one incoming message to the registered callback. Called by the IMP
    /// after it recovers `self` from the ivar and reads `message.body`. `body` is
    /// borrowed (WebKit-owned, autoreleased) — see `OnMessage`. This is the clean
    /// M2.3 seam: M2.3 replaces `on_message` (and/or this body) with extraction +
    /// std.json parse + dispatch, without touching the class-creation or IMP code.
    pub fn handleMessage(self: *Bridge, body: objc.Object) void {
        self.on_message(self, body);
    }

    /// Deregister the handler from the user content controller, free the dispatch
    /// table's backing storage, and release the owned `+1` handler instance.
    /// After this no message can fire against the (now potentially dangling)
    /// context pointer. Must be called on the main thread.
    ///
    /// The map only owns its own storage — the keys are borrowed static literals
    /// (see `DispatchTable`) and the values are function pointers, so freeing the
    /// map is sufficient and frees nothing it does not own.
    pub fn deinit(self: *Bridge) void {
        // HashMap.deinit (hash_map.zig:211): deinit(self: *Self) void.
        self.dispatch.deinit();

        const NSString = objc.getClass("NSString") orelse {
            // Foundation is gone — process is tearing down; nothing safe to do.
            self.handler.msgSend(void, "release", .{});
            return;
        };
        const name = nsString(NSString, message_handler_name);
        defer name.msgSend(void, "release", .{});
        self.ucc.msgSend(void, "removeScriptMessageHandlerForName:", .{name});
        self.handler.msgSend(void, "release", .{});
    }
};

/// The IMP backing `-[WkzScriptMessageHandler userContentController:didReceiveScriptMessage:]`.
///
/// Convention (verified against zig-objc `Class.addMethod`, src/class.zig:72-87):
/// C calling convention, first two params `c.id` self / `c.SEL` _cmd, then the
/// two selector arguments (the user content controller and the script message,
/// both `id`). zig-objc derives the `v@:@@` type encoding from this signature —
/// it is NOT hand-written.
///
/// Recovers the borrowed `*Bridge` from the handler's `wkz_ctx` ivar, reads
/// `-[WKScriptMessage body]` (a borrowed, autoreleased id owned by WebKit for
/// the call), and routes both to `Bridge.handleMessage`.
fn impUserContentControllerDidReceive(
    self: c.id,
    _cmd: c.SEL,
    user_content_controller: c.id,
    message: c.id,
) callconv(.c) void {
    _ = _cmd;
    _ = user_content_controller;

    const handler = objc.Object{ .value = self };

    // Recover the borrowed *Bridge from the id ivar. object_getIvar is a raw
    // pointer read (no retain) under MRC — the inverse of the raw store in
    // Bridge.attach.
    const ctx = handler.getInstanceVariable(ctx_ivar_name);
    if (ctx.value == null) {
        // No context wired — Bridge.attach() was never called (programming error).
        // std.debug.assert(false) panics in .Debug and .ReleaseSafe; in
        // .ReleaseFast/.ReleaseSmall the assert is elided and the message is
        // dropped safely (log.warn + return below).
        std.debug.assert(false);
        log.warn("dropped message: no context attached (stage=extraction)", .{});
        return;
    }
    const bridge: *Bridge = @ptrCast(@alignCast(ctx.value));

    // -[WKScriptMessage body] -> borrowed (autoreleased) id, WebKit-owned.
    const msg = objc.Object{ .value = message };
    const body = msg.msgSend(objc.Object, "body", .{});

    bridge.handleMessage(body);
}

/// Create (or look up) the runtime `WKScriptMessageHandler` subclass.
///
/// Open-coded per the M2.2 decision (NOT routed through
/// `objc_helpers.defineClass`, because that path takes no ivars): subclass
/// NSObject, add the `id`-typed `wkz_ctx` context ivar BEFORE registration, add
/// the `userContentController:didReceiveScriptMessage:` method, then register.
///
/// Idempotent: if the class is already registered (re-run / second webview), the
/// existing class is returned. A registered class lives for the process and is
/// not reference-counted — nothing to release.
fn handlerClass() Error!objc.Class {
    if (objc.getClass(handler_class_name)) |existing| return existing;

    const NSObject = objc.getClass("NSObject") orelse return Error.ClassNotFound;

    // objc_allocateClassPair fails (nil) on a duplicate name; we guarded that
    // above, so a nil here is a genuine allocation failure.
    const cls = objc.allocateClassPair(NSObject, handler_class_name) orelse
        return Error.ClassNotFound;

    // Ivars are only legal between allocateClassPair and registerClassPair.
    // addIvar adds an id-typed (pointer-width) slot; false would mean the layout
    // could not be extended, which is a programming error on a fresh pair.
    std.debug.assert(cls.addIvar(ctx_ivar_name));

    // addMethod asserts the IMP convention and derives the encoding from the fn
    // type. false only if the selector already exists — impossible on a fresh
    // pair, so a false here is a programming error.
    std.debug.assert(cls.addMethod(
        "userContentController:didReceiveScriptMessage:",
        impUserContentControllerDidReceive,
    ));

    objc.registerClassPair(cls);
    return cls;
}

/// Returns a `+1` NSString built from a UTF-8 C string. Caller owns it and must
/// `release` it. `-[NSString stringWithUTF8String:]` returns an autoreleased
/// string; since wkz drains no autorelease pool here, we `retain` it to get a
/// deterministic, ARC-free `+1` reference the caller releases explicitly.
fn nsString(NSString: objc.Class, str: [:0]const u8) objc.Object {
    const s = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{str.ptr});
    return s.msgSend(objc.Object, "retain", .{});
}

// =====================================================================
// Tests
//
// Runtime class creation + registration + ivar round-trip is headless-safe
// (M2.1 proved it). These LIVE tests create/register the handler class, assert
// it responds to the selector, round-trip a *Bridge through the ivar, and invoke
// the IMP directly (as a fn pointer) with crafted args to prove the context is
// recovered and the body is reached.
//
// A REAL JS postMessage round-trip needs a live WKWebView + run loop + a loaded
// page (not headless) and is deferred to the M2.2-G manual checklist.
// =====================================================================

test "handlerClass creates and registers the handler class responding to the selector" {
    const cls = try handlerClass();
    try std.testing.expect(objc.getClass(handler_class_name) != null);
    try std.testing.expectEqual(objc.getClass(handler_class_name).?.value, cls.value);

    // Instances respond to the WKScriptMessageHandler selector.
    try std.testing.expect(cls.msgSend(
        bool,
        "instancesRespondToSelector:",
        .{objc.sel("userContentController:didReceiveScriptMessage:").value},
    ));
}

test "handlerClass is idempotent across calls" {
    const a = try handlerClass();
    const b = try handlerClass();
    try std.testing.expectEqual(a.value, b.value);
}

test "handler instances do NOT respond to an unregistered selector (negative control)" {
    // The positive instancesRespondToSelector: assertion above is only meaningful
    // if the negative case reports false — i.e. the class does not trivially claim
    // every selector. A contrived selector NSObject also lacks must report false,
    // proving handlerClass() registers exactly the one WKScriptMessageHandler
    // method and no phantom selectors.
    const cls = try handlerClass();
    try std.testing.expect(!cls.msgSend(
        bool,
        "instancesRespondToSelector:",
        .{objc.sel("wkzNeverRegisteredOnHandler:").value},
    ));
}

test "the IMP nil-ivar guard returns without dereferencing an unwired context" {
    // A handler instance fresh from alloc/init has its wkz_ctx ivar zero-init'd
    // (no attach() ran). In DEBUG builds, hitting the null-ivar path fires
    // `std.debug.assert(false)` (a programming-error signal — see Bridge.init
    // doc). In RELEASE builds the assert is a no-op and the IMP drops the message
    // safely. This test only runs in non-debug modes; in debug mode the panic is
    // the expected (and desired) behavior.
    const builtin = @import("builtin");
    if (builtin.mode == .Debug) return error.SkipZigTest;

    const cls = try handlerClass();
    const handler = cls.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer handler.msgSend(void, "release", .{});

    // Confirm the precondition: the ivar really is null on a fresh instance.
    try std.testing.expect(handler.getInstanceVariable(ctx_ivar_name).value == null);

    // In release mode the assert is elided; the guard logs + returns safely
    // without dereferencing the null or touching the nil message.
    impUserContentControllerDidReceive(
        handler.value,
        objc.sel("userContentController:didReceiveScriptMessage:").value,
        null,
        null,
    );
}

test "the context *Bridge round-trips through the wkz_ctx ivar" {
    // Prove the no-ARC raw-pointer mechanism: store a *Bridge in the id ivar and
    // read the same address back. setInstanceVariable/getInstanceVariable use
    // object_setIvar/object_getIvar — raw pointer write/read, no retain.
    const cls = try handlerClass();
    const handler = cls.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer handler.msgSend(void, "release", .{});

    var bridge: Bridge = .{
        .handler = handler,
        .ucc = .{ .value = null },
        .webview = .{ .value = null },
        .on_message = dispatchMessage,
        .allocator = std.testing.allocator,
        .dispatch = DispatchTable.init(std.testing.allocator),
    };
    defer bridge.dispatch.deinit();

    handler.setInstanceVariable(ctx_ivar_name, .{ .value = @ptrCast(&bridge) });
    const got = handler.getInstanceVariable(ctx_ivar_name);
    try std.testing.expect(got.value != null);
    const recovered: *Bridge = @ptrCast(@alignCast(got.value));
    try std.testing.expectEqual(&bridge, recovered);
}

// --- IMP-reaches-body test plumbing ---
//
// A capturing callback proves the IMP recovered the context and reached the
// body. We cannot use a closure (no ARC blocks, and the callback is a plain fn
// pointer), so route through a module-level capture struct.

const ImpProbe = struct {
    var fired: bool = false;
    var body_utf8: [64]u8 = undefined;
    var body_len: usize = 0;

    fn onMessage(bridge: *Bridge, body: objc.Object) void {
        _ = bridge;
        fired = true;
        body_len = 0;
        if (body.value == null) return;
        const utf8 = body.msgSend([*:0]const u8, "UTF8String", .{});
        const span = std.mem.span(utf8);
        const n = @min(span.len, body_utf8.len);
        @memcpy(body_utf8[0..n], span[0..n]);
        body_len = n;
    }
};

test "invoking the IMP directly recovers the context and reaches the body" {
    // Construct a handler instance, wire a *Bridge with a capturing callback into
    // the ivar, then call the IMP as a function pointer with crafted id args:
    //   self  = the handler
    //   _cmd  = the selector
    //   ucc   = nil (the IMP ignores it for M2.2)
    //   msg   = a stand-in WKScriptMessage. Building a real WKScriptMessage is
    //           impractical headless (it needs a live frame), so we pass an
    //           NSObject subclass instance that responds to -body by returning an
    //           NSString. The IMP only sends -body, so any object answering -body
    //           with an id satisfies the contract under test.
    const cls = try handlerClass();
    const handler = cls.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer handler.msgSend(void, "release", .{});

    var bridge: Bridge = .{
        .handler = handler,
        .ucc = .{ .value = null },
        .webview = .{ .value = null },
        .on_message = ImpProbe.onMessage,
        .allocator = std.testing.allocator,
        .dispatch = DispatchTable.init(std.testing.allocator),
    };
    defer bridge.dispatch.deinit();
    handler.setInstanceVariable(ctx_ivar_name, .{ .value = @ptrCast(&bridge) });

    // A stand-in "message" whose -body returns a known NSString.
    const FakeMessage = try fakeMessageClass();
    const fake = FakeMessage.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer fake.msgSend(void, "release", .{});

    ImpProbe.fired = false;
    impUserContentControllerDidReceive(
        handler.value,
        objc.sel("userContentController:didReceiveScriptMessage:").value,
        null,
        fake.value,
    );

    try std.testing.expect(ImpProbe.fired);
    try std.testing.expectEqualStrings("hello-from-js", ImpProbe.body_utf8[0..ImpProbe.body_len]);
}

/// IMP for the stand-in message's `-body`: returns a fixed NSString so the
/// direct-IMP test can assert the body is reached. Encoding `@@:` (id return,
/// id self, SEL _cmd) is derived by zig-objc.
fn fakeBodyImp(self: c.id, _cmd: c.SEL) callconv(.c) c.id {
    _ = self;
    _ = _cmd;
    const NSString = objc.getClass("NSString").?;
    const s = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"hello-from-js"});
    return s.value;
}

/// Create a tiny NSObject subclass that answers `-body` with a known NSString,
/// standing in for a WKScriptMessage in the direct-IMP test. Idempotent;
/// process-lived.
fn fakeMessageClass() Error!objc.Class {
    const name: [:0]const u8 = "WkzFakeScriptMessage";
    if (objc.getClass(name)) |existing| return existing;
    const NSObject = objc.getClass("NSObject") orelse return Error.ClassNotFound;
    const cls = objc.allocateClassPair(NSObject, name) orelse return Error.ClassNotFound;
    std.debug.assert(cls.addMethod("body", fakeBodyImp));
    objc.registerClassPair(cls);
    return cls;
}

// --- Parse + dispatch core (pure logic; fully headless) ---
//
// These exercise `dispatchSlice` directly with crafted JSON slices — no NSString
// and no IMP needed. A module-level capture struct records the last invocation
// (Zig has no closures over a plain fn-pointer handler). std.testing.allocator
// is used throughout so any leak in the parse arena / map fails the test.

const DispatchProbe = struct {
    var fired: bool = false;
    var saw_string: ?[]const u8 = null; // a copied-out param string, if any
    var buf: [64]u8 = undefined;

    fn reset() void {
        fired = false;
        saw_string = null;
        last_id = null;
    }

    /// Handler that records it ran, the received `id`, and copies a `params.name`
    /// string (if the params is an object with a string `name`) into a static
    /// buffer. We copy because the params Value borrows the parse arena, which is
    /// freed once dispatchSlice returns.
    var last_id: ?i64 = null;

    fn record(bridge: *Bridge, params: std.json.Value, id: ?i64) void {
        _ = bridge;
        fired = true;
        last_id = id;
        switch (params) {
            .object => |obj| {
                if (obj.get("name")) |v| switch (v) {
                    .string => |s| {
                        const n = @min(s.len, buf.len);
                        @memcpy(buf[0..n], s[0..n]);
                        saw_string = buf[0..n];
                    },
                    else => {},
                };
            },
            else => {},
        }
    }
};

/// Build a Bridge backed by `std.testing.allocator` without touching AppKit/the
/// run loop: alloc/init a handler instance (so deinit's release is balanced) and
/// an empty dispatch map. Caller must `defer bridge.deinit()` (which releases the
/// handler and frees the map). ucc is nil; deinit's removeScriptMessageHandler
/// against a nil ucc is a no-op send, safe headless.
fn makeTestBridge() !Bridge {
    const cls = try handlerClass();
    const handler = cls.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    return .{
        .handler = handler,
        .ucc = .{ .value = null },
        .webview = .{ .value = null },
        .on_message = dispatchMessage,
        .allocator = std.testing.allocator,
        .dispatch = DispatchTable.init(std.testing.allocator),
    };
}

test "dispatchSlice: valid JSON with a registered method invokes the handler with params" {
    var bridge = try makeTestBridge();
    defer bridge.deinit();
    try bridge.addHandler("greet", DispatchProbe.record);

    DispatchProbe.reset();
    try bridge.dispatchSlice(
        \\{"method":"greet","params":{"name":"ada"},"id":7}
    );
    try std.testing.expect(DispatchProbe.fired);
    try std.testing.expect(DispatchProbe.saw_string != null);
    try std.testing.expectEqualStrings("ada", DispatchProbe.saw_string.?);
}

test "dispatchSlice: missing params defaults to .null and still dispatches" {
    var bridge = try makeTestBridge();
    defer bridge.deinit();
    try bridge.addHandler("ping", DispatchProbe.record);

    DispatchProbe.reset();
    try bridge.dispatchSlice(
        \\{"method":"ping"}
    );
    try std.testing.expect(DispatchProbe.fired);
    // No params object -> handler saw .null -> recorded no string.
    try std.testing.expect(DispatchProbe.saw_string == null);
}

test "dispatchSlice: unknown method returns UnknownMethod, no handler runs" {
    var bridge = try makeTestBridge();
    defer bridge.deinit();
    try bridge.addHandler("known", DispatchProbe.record);

    DispatchProbe.reset();
    try std.testing.expectError(DispatchError.UnknownMethod, bridge.dispatchSlice(
        \\{"method":"nope","params":1}
    ));
    try std.testing.expect(!DispatchProbe.fired);
}

test "dispatchSlice: malformed JSON returns InvalidMessage, no crash, no leak" {
    var bridge = try makeTestBridge();
    defer bridge.deinit();
    try bridge.addHandler("x", DispatchProbe.record);

    DispatchProbe.reset();
    // Truncated / garbage input. Must surface a clean error, never panic, and
    // the testing allocator must report no leak (the parse arena is freed even
    // on the error path).
    try std.testing.expectError(DispatchError.InvalidMessage, bridge.dispatchSlice("{not json"));
    try std.testing.expectError(DispatchError.InvalidMessage, bridge.dispatchSlice(""));
    // Valid JSON but not an object: also InvalidMessage.
    try std.testing.expectError(DispatchError.InvalidMessage, bridge.dispatchSlice("[1,2,3]"));
    try std.testing.expectError(DispatchError.InvalidMessage, bridge.dispatchSlice("42"));
    try std.testing.expect(!DispatchProbe.fired);
}

test "dispatchSlice: missing or non-string method returns MissingMethod" {
    var bridge = try makeTestBridge();
    defer bridge.deinit();

    DispatchProbe.reset();
    // No method key.
    try std.testing.expectError(DispatchError.MissingMethod, bridge.dispatchSlice(
        \\{"params":{}}
    ));
    // method present but not a string.
    try std.testing.expectError(DispatchError.MissingMethod, bridge.dispatchSlice(
        \\{"method":123}
    ));
    try std.testing.expect(!DispatchProbe.fired);
}

test "addHandler: last registration for a method wins" {
    var bridge = try makeTestBridge();
    defer bridge.deinit();

    const First = struct {
        var ran: bool = false;
        fn h(_: *Bridge, _: std.json.Value, _: ?i64) void {
            ran = true;
        }
    };
    First.ran = false;

    try bridge.addHandler("m", First.h);
    try bridge.addHandler("m", DispatchProbe.record); // overwrites

    DispatchProbe.reset();
    try bridge.dispatchSlice(
        \\{"method":"m","params":{}}
    );
    try std.testing.expect(DispatchProbe.fired);
    try std.testing.expect(!First.ran);
}

test "dispatchSlice: unknown-method path frees the parse arena (no leak under testing.allocator)" {
    // The MAJOR-risk path the reviewer cared about: a WELL-FORMED message whose
    // `method` parses cleanly (so parseFromSlice succeeds and the arena is
    // allocated) but is NOT registered, so dispatchSlice early-returns
    // UnknownMethod BEFORE invoking any handler. Run under testing.allocator: the
    // `defer parsed.deinit()` must free the arena on THIS early-return path, or
    // the allocator reports a leak and fails the test. A handler is registered
    // (different name) to prove the early return is the unknown-method branch,
    // not an empty-table shortcut.
    var bridge = try makeTestBridge();
    defer bridge.deinit();
    try bridge.addHandler("registered", DispatchProbe.record);

    DispatchProbe.reset();
    // params carries a nested object + array so the arena actually allocates
    // child nodes (a flat scalar might be a degenerate arena); freeing those on
    // the early-return path is exactly what we are proving.
    try std.testing.expectError(DispatchError.UnknownMethod, bridge.dispatchSlice(
        \\{"method":"not-registered","params":{"a":[1,2,3],"b":{"c":"d"}},"id":99}
    ));
    try std.testing.expect(!DispatchProbe.fired);
    // No explicit leak assertion needed: std.testing.allocator panics at test end
    // on any unfreed allocation, so reaching here clean proves the arena was freed.
}

const NestedProbe = struct {
    var fired: bool = false;
    var arr_len: usize = 0;
    var arr0: i64 = 0;
    var arr1: i64 = 0;
    var deep: [64]u8 = undefined;
    var deep_len: usize = 0;
    var saw_deep: bool = false;

    fn reset() void {
        fired = false;
        arr_len = 0;
        arr0 = 0;
        arr1 = 0;
        deep_len = 0;
        saw_deep = false;
    }

    /// Reads params.list (an array of integers) and params.obj.deep (a nested
    /// string), copying the string out (it borrows the parse arena). Proves
    /// arrays and multi-level objects reach the handler intact through dispatch.
    fn record(_: *Bridge, params: std.json.Value, _: ?i64) void {
        fired = true;
        const obj = switch (params) {
            .object => |o| o,
            else => return,
        };
        if (obj.get("list")) |v| switch (v) {
            .array => |a| {
                arr_len = a.items.len;
                if (a.items.len > 0) if (a.items[0] == .integer) {
                    arr0 = a.items[0].integer;
                };
                if (a.items.len > 1) if (a.items[1] == .integer) {
                    arr1 = a.items[1].integer;
                };
            },
            else => {},
        };
        if (obj.get("obj")) |v| switch (v) {
            .object => |inner| {
                if (inner.get("deep")) |dv| switch (dv) {
                    .string => |s| {
                        const n = @min(s.len, deep.len);
                        @memcpy(deep[0..n], s[0..n]);
                        deep_len = n;
                        saw_deep = true;
                    },
                    else => {},
                };
            },
            else => {},
        };
    }
};

test "dispatchSlice: nested object + array params reach the handler intact" {
    // Beyond the existing flat params.name test: prove an array (params.list) and
    // a two-level nested object (params.obj.deep) survive the parse + dispatch and
    // are readable in the handler with correct element values.
    var bridge = try makeTestBridge();
    defer bridge.deinit();
    try bridge.addHandler("rich", NestedProbe.record);

    NestedProbe.reset();
    try bridge.dispatchSlice(
        \\{"method":"rich","params":{"list":[10,20,30],"obj":{"deep":"buried"}}}
    );
    try std.testing.expect(NestedProbe.fired);
    try std.testing.expectEqual(@as(usize, 3), NestedProbe.arr_len);
    try std.testing.expectEqual(@as(i64, 10), NestedProbe.arr0);
    try std.testing.expectEqual(@as(i64, 20), NestedProbe.arr1);
    try std.testing.expect(NestedProbe.saw_deep);
    try std.testing.expectEqualStrings("buried", NestedProbe.deep[0..NestedProbe.deep_len]);
}

const ShapeProbe = struct {
    var fired: bool = false;
    var tag: std.meta.Tag(std.json.Value) = .null;
    var int_val: i64 = 0;
    var str: [64]u8 = undefined;
    var str_len: usize = 0;

    fn reset() void {
        fired = false;
        tag = .null;
        int_val = 0;
        str_len = 0;
    }

    /// Records that it ran and the active union tag of whatever `params` was,
    /// without assuming any shape. Proves dispatch does NOT validate param type.
    fn record(_: *Bridge, params: std.json.Value, _: ?i64) void {
        fired = true;
        tag = std.meta.activeTag(params);
        switch (params) {
            .integer => |i| int_val = i,
            .string => |s| {
                const n = @min(s.len, str.len);
                @memcpy(str[0..n], s[0..n]);
                str_len = n;
            },
            else => {},
        }
    }
};

test "dispatchSlice: params of a non-object type is passed through to the handler unvalidated" {
    // Pin the actual contract: dispatch does NOT validate the SHAPE of params. A
    // message with `params` as a bare JSON number must still invoke the handler,
    // handing it a `.integer` Value. (Param-shape validation is a handler/M3
    // concern, deliberately not done here.) This documents the behaviour so a
    // future change that starts rejecting non-object params is caught.
    var bridge = try makeTestBridge();
    defer bridge.deinit();
    try bridge.addHandler("scalar", ShapeProbe.record);

    ShapeProbe.reset();
    try bridge.dispatchSlice(
        \\{"method":"scalar","params":42}
    );
    try std.testing.expect(ShapeProbe.fired);
    try std.testing.expectEqual(.integer, ShapeProbe.tag);
    try std.testing.expectEqual(@as(i64, 42), ShapeProbe.int_val);

    // A JSON-string params is likewise passed through as .string, not coerced.
    ShapeProbe.reset();
    try bridge.dispatchSlice(
        \\{"method":"scalar","params":"raw"}
    );
    try std.testing.expect(ShapeProbe.fired);
    try std.testing.expectEqual(.string, ShapeProbe.tag);
    try std.testing.expectEqualStrings("raw", ShapeProbe.str[0..ShapeProbe.str_len]);
}

test "dispatchSlice: with multiple handlers registered, method routes to the matching one only" {
    // The existing tests register a single method; this proves the hashmap LOOKUP
    // actually discriminates by key. Three distinct methods are registered, each
    // flipping its own flag; dispatching "two" must fire ONLY handler two.
    const Multi = struct {
        var one: bool = false;
        var two: bool = false;
        var three: bool = false;
        fn h1(_: *Bridge, _: std.json.Value, _: ?i64) void {
            one = true;
        }
        fn h2(_: *Bridge, _: std.json.Value, _: ?i64) void {
            two = true;
        }
        fn h3(_: *Bridge, _: std.json.Value, _: ?i64) void {
            three = true;
        }
    };
    Multi.one = false;
    Multi.two = false;
    Multi.three = false;

    var bridge = try makeTestBridge();
    defer bridge.deinit();
    try bridge.addHandler("one", Multi.h1);
    try bridge.addHandler("two", Multi.h2);
    try bridge.addHandler("three", Multi.h3);

    try bridge.dispatchSlice(
        \\{"method":"two"}
    );
    try std.testing.expect(!Multi.one);
    try std.testing.expect(Multi.two);
    try std.testing.expect(!Multi.three);

    // Route a different key and confirm it lands on its own handler, leaving the
    // others as last set (one still false, two still true, three now true).
    try bridge.dispatchSlice(
        \\{"method":"three"}
    );
    try std.testing.expect(!Multi.one);
    try std.testing.expect(Multi.three);
}

test "deinit frees a populated dispatch table (no leak with N registered handlers)" {
    // The existing deinit coverage runs against an effectively empty/small map.
    // Register several handlers so the map grows its backing storage, then let
    // `defer bridge.deinit()` free it under testing.allocator. A leak in deinit's
    // `self.dispatch.deinit()` for a populated map would fail at test end. Keys
    // are static literals (not owned by the map), so only the map's own storage
    // must be freed — this proves that is sufficient and complete.
    var bridge = try makeTestBridge();
    defer bridge.deinit();

    const Noop = struct {
        fn h(_: *Bridge, _: std.json.Value, _: ?i64) void {}
    };
    try bridge.addHandler("alpha", Noop.h);
    try bridge.addHandler("bravo", Noop.h);
    try bridge.addHandler("charlie", Noop.h);
    try bridge.addHandler("delta", Noop.h);
    try bridge.addHandler("echo", Noop.h);
    try bridge.addHandler("foxtrot", Noop.h);
    try bridge.addHandler("golf", Noop.h);
    try bridge.addHandler("hotel", Noop.h);

    try std.testing.expectEqual(@as(u32, 8), bridge.dispatch.count());
    // No body needed: the defer'd deinit + testing.allocator end-of-test leak
    // check is the assertion that the populated map is fully freed.
}

test "dispatchMessage: NSString body extracts to UTF-8 and dispatches (ObjC leg, headless)" {
    // Proves the NSString -> UTF8String -> slice extraction leg with a real
    // NSString (built headlessly via stringWithUTF8String:), feeding a JSON
    // document through the default on_message path into the dispatch table.
    var bridge = try makeTestBridge();
    defer bridge.deinit();
    try bridge.addHandler("greet", DispatchProbe.record);

    const NSString = objc.getClass("NSString").?;
    const json: [:0]const u8 =
        \\{"method":"greet","params":{"name":"grace"}}
    ;
    // Autoreleased NSString (we drain no pool, and UTF8String is borrowed): we
    // do not release or free anything from this string.
    const body = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{json.ptr});

    DispatchProbe.reset();
    dispatchMessage(&bridge, body);
    try std.testing.expect(DispatchProbe.fired);
    try std.testing.expectEqualStrings("grace", DispatchProbe.saw_string.?);
}

// =====================================================================
// M2.4 — adversarial battery: "malformed input logs, never crashes"
//
// Every test below runs under std.testing.allocator (leak-detecting). The
// contract under test on the PURE core (`dispatchSlice`) is: for ANY input
// shape, return a clean `DispatchError` (asserted kind) OR dispatch — never
// panic, never leak. The void boundary (`dispatchMessage`) is exercised
// separately to prove it logs + SWALLOWS (returns void, no error escapes).
// =====================================================================

test "M2.4 dispatchSlice: oversized body is rejected BEFORE parse (MessageTooLarge, no leak)" {
    // Construct a body exactly one byte over `max_body_len`. It must be rejected
    // by the size guard before any parse arena is allocated — so testing.allocator
    // reports no leak (there was nothing to free). The slice contents are valid
    // JSON-ish bytes so the ONLY thing rejecting it is the length check, not a
    // parse error. We allocate the transient over-cap slice with the testing
    // allocator and free it ourselves (this is the test's buffer, not the
    // bridge's — the bridge allocates nothing on this path).
    var bridge = try makeTestBridge();
    defer bridge.deinit();
    try bridge.addHandler("x", DispatchProbe.record);

    const oversized = try std.testing.allocator.alloc(u8, max_body_len + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' '); // whitespace: would be a parse error if it reached the parser

    DispatchProbe.reset();
    try std.testing.expectError(DispatchError.MessageTooLarge, bridge.dispatchSlice(oversized));
    try std.testing.expect(!DispatchProbe.fired);

    // A body exactly AT the cap is NOT rejected by size (it falls through to the
    // parser, which then rejects whitespace as InvalidMessage). Proves the
    // boundary is `> cap`, not `>= cap`, and that the size path allocates nothing.
    const at_cap = try std.testing.allocator.alloc(u8, max_body_len);
    defer std.testing.allocator.free(at_cap);
    @memset(at_cap, ' ');
    try std.testing.expectError(DispatchError.InvalidMessage, bridge.dispatchSlice(at_cap));
}

test "M2.4 dispatchSlice: deeply nested JSON returns a clean error, never a stack overflow/panic" {
    // THE key anti-panic test. std.json parses to Value ITERATIVELY (an explicit
    // heap Array stack, json/dynamic.zig:79-119) and tracks nesting on a heap
    // BitStack (json/Scanner.zig:328-334) — memory is O(depth), NOT C-stack. So
    // pathological nesting exhausts the allocator at worst (folded into
    // InvalidMessage), it does NOT recurse the native stack and cannot overflow
    // it. We build 50k open brackets (well within max_body_len) and assert a
    // clean error comes back rather than the test process crashing. Reaching the
    // assertion at all IS the proof there was no stack overflow / panic.
    var bridge = try makeTestBridge();
    defer bridge.deinit();

    const depth = 50_000;
    const deep = try std.testing.allocator.alloc(u8, depth);
    defer std.testing.allocator.free(deep);
    @memset(deep, '['); // 50k unbalanced '[' — never completes a value
    try std.testing.expect(deep.len <= max_body_len);

    // Must return InvalidMessage (incomplete/too-deep document), not crash.
    try std.testing.expectError(DispatchError.InvalidMessage, bridge.dispatchSlice(deep));
}

test "M2.4 dispatchSlice: i64-overflow number is handled, no panic" {
    // A number too large for i64. With parse_numbers=true (the default), std.json
    // yields `.number_string` for such a value rather than panicking on an i64
    // cast. Either way dispatchSlice must not panic: here it is a well-formed
    // object with a known method, so it dispatches and the handler receives the
    // params unvalidated (the .number_string is just passed through).
    var bridge = try makeTestBridge();
    defer bridge.deinit();
    try bridge.addHandler("big", ShapeProbe.record);

    ShapeProbe.reset();
    try bridge.dispatchSlice(
        \\{"method":"big","params":99999999999999999999999999}
    );
    try std.testing.expect(ShapeProbe.fired);
    // Pin the observed representation: a value past i64 range comes through as
    // number_string, never an .integer (which would have implied a lossy/overflow
    // cast). If this ever flips, we want the test to flag it.
    try std.testing.expectEqual(.number_string, ShapeProbe.tag);
}

test "M2.4 dispatchSlice: invalid UTF-8 inside the body returns a clean error, no panic" {
    var bridge = try makeTestBridge();
    defer bridge.deinit();
    try bridge.addHandler("x", DispatchProbe.record);

    // A JSON string containing a lone 0x80 continuation byte (invalid UTF-8).
    const bad = [_]u8{ '{', '"', 'm', 'e', 't', 'h', 'o', 'd', '"', ':', '"', 0x80, '"', '}' };
    DispatchProbe.reset();
    try std.testing.expectError(DispatchError.InvalidMessage, bridge.dispatchSlice(&bad));
    try std.testing.expect(!DispatchProbe.fired);
}

test "M2.4 dispatchSlice: hostile input-shape matrix — each logs/returns the exact outcome, no panic, no leak" {
    // The full shape matrix from the M2.4 spec. Every case runs under
    // testing.allocator; an entry that leaked the parse arena (e.g. a missed
    // deinit on some early-return path) would fail the test at teardown. None may
    // panic. Each row asserts the precise DispatchError kind (or, for the known
    // method, a successful dispatch handled below).
    var bridge = try makeTestBridge();
    defer bridge.deinit();
    try bridge.addHandler("known", DispatchProbe.record);

    const Case = struct { body: []const u8, want: DispatchError };
    const cases = [_]Case{
        .{ .body = "", .want = DispatchError.InvalidMessage }, // empty
        .{ .body = "   ", .want = DispatchError.InvalidMessage }, // whitespace-only
        .{ .body = "\t\n ", .want = DispatchError.InvalidMessage }, // mixed whitespace
        .{ .body = "null", .want = DispatchError.InvalidMessage }, // valid JSON null
        .{ .body = "true", .want = DispatchError.InvalidMessage }, // valid JSON bool
        .{ .body = "\"a string\"", .want = DispatchError.InvalidMessage }, // top-level string
        .{ .body = "[1,2]", .want = DispatchError.InvalidMessage }, // top-level array
        .{ .body = "{not json", .want = DispatchError.InvalidMessage }, // truncated garbage
        .{ .body = "{}", .want = DispatchError.MissingMethod }, // object, no method
        .{ .body =
        \\{"method":null}
        , .want = DispatchError.MissingMethod }, // method present but null
        .{ .body =
        \\{"method":123}
        , .want = DispatchError.MissingMethod }, // method present but a number
        .{ .body =
        \\{"method":["x"]}
        , .want = DispatchError.MissingMethod }, // method present but an array
        .{ .body =
        \\{"method":"nope"}
        , .want = DispatchError.UnknownMethod }, // valid + unknown method
        .{ .body =
        \\{"method":"nope","params":null}
        , .want = DispatchError.UnknownMethod }, // unknown wins over null params
    };

    for (cases) |case| {
        DispatchProbe.reset();
        try std.testing.expectError(case.want, bridge.dispatchSlice(case.body));
        try std.testing.expect(!DispatchProbe.fired);
    }

    // method present + params null (registered method): null params must be
    // tolerated — the handler runs, receiving a .null params value.
    DispatchProbe.reset();
    try bridge.dispatchSlice(
        \\{"method":"known","params":null}
    );
    try std.testing.expect(DispatchProbe.fired);
    try std.testing.expect(DispatchProbe.saw_string == null); // null params -> no name

    // method present, params absent (registered method): also dispatches.
    DispatchProbe.reset();
    try bridge.dispatchSlice(
        \\{"method":"known"}
    );
    try std.testing.expect(DispatchProbe.fired);
}

test "M2.4 dispatchSlice: duplicate object keys return a clean error, no panic, no leak" {
    // Duplicate keys are an attacker-trivial shape. Parsing to a dynamic Value
    // with the DEFAULT ParseOptions (`duplicate_field_behavior = .@"error"`,
    // json/static.zig:22-26) makes std.json return `error.DuplicateField`
    // (json/dynamic.zig:152) — which dispatchSlice folds into InvalidMessage. The
    // load-bearing assertion is that this is a clean ERROR return, NOT a panic /
    // process crash, and that the partially-built arena is freed (no leak under
    // testing.allocator). Reaching the assertion proves no crash.
    var bridge = try makeTestBridge();
    defer bridge.deinit();
    try bridge.addHandler("dup", DispatchProbe.record);

    DispatchProbe.reset();
    try std.testing.expectError(DispatchError.InvalidMessage, bridge.dispatchSlice(
        \\{"method":"dup","method":"dup","params":{"name":"z"}}
    ));
    try std.testing.expect(!DispatchProbe.fired);
}

test "M2.4 dispatchMessage (void boundary): hostile bodies log + SWALLOW, return void, no error escapes" {
    // Drive the void IMP-boundary path with real NSStrings built headlessly via
    // stringWithUTF8String:. For each hostile body dispatchMessage must return
    // VOID (it has no error type — proving by construction no DispatchError can
    // escape into the C-ABI IMP). No handler fires; nothing leaks. We cover the
    // size, parse, missing-method and unknown-method stages through the real
    // NSString extraction leg.
    var bridge = try makeTestBridge();
    defer bridge.deinit();
    try bridge.addHandler("known", DispatchProbe.record);

    const NSString = objc.getClass("NSString").?;
    const bodies = [_][:0]const u8{
        "", // empty -> parse stage
        "   ", // whitespace -> parse stage
        "{not json", // garbage -> parse stage
        "[1,2,3]", // not-an-object -> parse stage
        "{}", // missing-method stage
        \\{"method":123}
        , // non-string method -> missing-method stage
        \\{"method":"nope"}
        , // unknown-method stage
    };

    for (bodies) |b| {
        DispatchProbe.reset();
        const body = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{b.ptr});
        // The call returns void: if dispatchMessage's signature ever grew an
        // error type, this line would fail to compile — the compiler enforces the
        // "no error escapes the boundary" contract for us.
        dispatchMessage(&bridge, body);
        try std.testing.expect(!DispatchProbe.fired);
    }

    // Regression: a well-formed known message through the SAME void boundary still
    // dispatches (the swallowing path did not break the happy path).
    DispatchProbe.reset();
    const ok = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{
        \\{"method":"known","params":{"name":"ok"}}
    });
    dispatchMessage(&bridge, ok);
    try std.testing.expect(DispatchProbe.fired);
    try std.testing.expectEqualStrings("ok", DispatchProbe.saw_string.?);
}

test "M2.4 dispatchMessage signature: returns void (no error union can escape to the IMP)" {
    // Compile-time proof of the void-boundary contract: dispatchMessage and the
    // public handleMessage seam both return plain `void`, so the C-ABI IMP can
    // never receive a Zig error from them. (dispatchSlice, the pure core, DOES
    // return DispatchError — that error is consumed by the catch in
    // dispatchMessage, never propagated.)
    try std.testing.expectEqual(void, @typeInfo(@TypeOf(dispatchMessage)).@"fn".return_type.?);
    try std.testing.expectEqual(void, @typeInfo(@TypeOf(Bridge.handleMessage)).@"fn".return_type.?);
}

test "M2.4 max_body_len is a sane, documented constant" {
    // Pin the cap so an accidental change is caught. 1 MiB: far above any
    // legitimate local RPC payload, bounded enough to deny memory-pressure DoS.
    try std.testing.expectEqual(@as(usize, 1 * 1024 * 1024), max_body_len);
}

// =====================================================================
// M3.1 — buildResolveJS / resolve / evaluate
//
// `buildResolveJS` is pure Zig (no ObjC), fully headless-testable.
// `evaluate` / `resolve` call WebKit — not headless-safe with a live webview —
// so the ObjC leg is tested only at the compile-time / selector-respond level.
// =====================================================================

test "buildResolveJS: positive id + quoted string result" {
    const js = try Bridge.buildResolveJS(7, "\"hello\"", std.testing.allocator);
    defer std.testing.allocator.free(js);
    try std.testing.expectEqualStrings("__resolve(7, \"hello\")", js);
    // Result must be NUL-terminated ([:0]u8 sentinel).
    try std.testing.expectEqual(@as(u8, 0), js[js.len]);
}

test "buildResolveJS: zero id" {
    const js = try Bridge.buildResolveJS(0, "null", std.testing.allocator);
    defer std.testing.allocator.free(js);
    try std.testing.expectEqualStrings("__resolve(0, null)", js);
}

test "buildResolveJS: negative id" {
    const js = try Bridge.buildResolveJS(-1, "42", std.testing.allocator);
    defer std.testing.allocator.free(js);
    try std.testing.expectEqualStrings("__resolve(-1, 42)", js);
}

test "buildResolveJS: empty result" {
    const js = try Bridge.buildResolveJS(1, "", std.testing.allocator);
    defer std.testing.allocator.free(js);
    try std.testing.expectEqualStrings("__resolve(1, )", js);
}

test "buildResolveJS: result with special characters" {
    const js = try Bridge.buildResolveJS(99, "{\"a\":1,\"b\":\"x\\ny\"}", std.testing.allocator);
    defer std.testing.allocator.free(js);
    try std.testing.expectEqualStrings("__resolve(99, {\"a\":1,\"b\":\"x\\ny\"})", js);
}

test "buildResolveJS: large id values" {
    const js = try Bridge.buildResolveJS(std.math.maxInt(i64), "true", std.testing.allocator);
    defer std.testing.allocator.free(js);
    // Just assert it contains the max int formatted correctly (not truncated).
    try std.testing.expect(std.mem.startsWith(u8, js, "__resolve(9223372036854775807, true)"));
}

test "evaluate and resolve return void (compile-time contract)" {
    // evaluate is `fn (*Bridge, [:0]const u8) void`
    try std.testing.expectEqual(
        void,
        @typeInfo(@TypeOf(Bridge.evaluate)).@"fn".return_type.?,
    );
    // resolve is `fn (*Bridge, i64, []const u8) Allocator.Error!void`
    try std.testing.expectEqual(
        std.mem.Allocator.Error!void,
        @typeInfo(@TypeOf(Bridge.resolve)).@"fn".return_type.?,
    );
}

test "WKWebView responds to evaluateJavaScript:completionHandler:" {
    // Selector-respond check: proves the selector string is spelled correctly and
    // WKWebView instances handle it — headlessly safe (class metadata query, no
    // window server, no live webview).
    const WKWebView = objc.getClass("WKWebView").?;
    try std.testing.expect(WKWebView.msgSend(
        bool,
        "instancesRespondToSelector:",
        .{objc.sel("evaluateJavaScript:completionHandler:").value},
    ));
}

test "buildResolveJS: result containing a bare double-quote is injected raw (caller-must-encode contract)" {
    // The doc comment states `result` is a raw JS expression — the caller is
    // responsible for quoting/encoding. This test pins that a bare `"` inside
    // `result` appears VERBATIM in the output, NOT HTML/JSON-escaped. Any future
    // change that starts escaping the result would break the public contract and
    // must be an explicit, documented decision.
    const js = try Bridge.buildResolveJS(1, "\"", std.testing.allocator);
    defer std.testing.allocator.free(js);
    try std.testing.expectEqualStrings("__resolve(1, \")", js);
    // Sentinel is intact even with a quote in the body.
    try std.testing.expectEqual(@as(u8, 0), js[js.len]);
}

test "buildResolveJS: minimum i64 value" {
    // Complement to the maxInt test: proves the signed lower bound is formatted
    // correctly (the leading minus plus all digits, no truncation/overflow).
    const js = try Bridge.buildResolveJS(std.math.minInt(i64), "false", std.testing.allocator);
    defer std.testing.allocator.free(js);
    try std.testing.expectEqualStrings("__resolve(-9223372036854775808, false)", js);
}

test "buildResolveJS: OOM returns Allocator.Error (no crash, nothing leaked)" {
    // Provoke an allocator failure on the very first allocation. `buildResolveJS`
    // calls `std.fmt.allocPrintSentinel` which allocates; with fail_index=0 that
    // allocation fails immediately and `OutOfMemory` must propagate cleanly out of
    // `buildResolveJS`. Nothing is allocated on this path so there is nothing to
    // leak (the FailingAllocator itself lives on the stack).
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    const result = Bridge.buildResolveJS(42, "\"x\"", failing.allocator());
    try std.testing.expectError(error.OutOfMemory, result);
}

test "Bridge exposes buildResolveJS as a public decl with the correct signature" {
    // `buildResolveJS` is a free function in the Bridge namespace (not a method —
    // it takes no `*Bridge`). Confirm it is public, callable, and returns the
    // documented type.
    try std.testing.expect(@hasDecl(Bridge, "buildResolveJS"));
    const Ret = @typeInfo(@TypeOf(Bridge.buildResolveJS)).@"fn".return_type.?;
    try std.testing.expectEqual(std.mem.Allocator.Error![:0]u8, Ret);
}

test "resolve allocates, calls evaluate with correct JS, and frees (nil webview guard)" {
    // `evaluate` guards `objc.getClass("NSString") orelse return` — so with a
    // nil webview field it returns immediately without crashing. `resolve` still
    // allocates the JS string, calls `evaluate`, and frees the string. Under
    // `std.testing.allocator` any leak fails the test, proving the free path is
    // taken even when `evaluate` returns early.
    var bridge = try makeTestBridge(); // webview is nil
    defer bridge.deinit();
    try bridge.resolve(7, "\"hello\"");
    // Reaching here without a testing.allocator leak assertion failure proves
    // the allocate-evaluate-free cycle completes cleanly.
}

// =====================================================================
// M3.2 — registerHandler + id correlation tests
// =====================================================================

test "dispatchSlice: id present as integer is passed to handler" {
    var bridge = try makeTestBridge();
    defer bridge.deinit();
    try bridge.addHandler("ping", DispatchProbe.record);

    DispatchProbe.reset();
    try bridge.dispatchSlice(
        \\{"method":"ping","params":{},"id":7}
    );
    try std.testing.expect(DispatchProbe.fired);
    try std.testing.expectEqual(@as(?i64, 7), DispatchProbe.last_id);
}

test "dispatchSlice: id absent → handler receives null id" {
    var bridge = try makeTestBridge();
    defer bridge.deinit();
    try bridge.addHandler("ping", DispatchProbe.record);

    DispatchProbe.reset();
    try bridge.dispatchSlice(
        \\{"method":"ping","params":{}}
    );
    try std.testing.expect(DispatchProbe.fired);
    try std.testing.expectEqual(@as(?i64, null), DispatchProbe.last_id);
}

test "dispatchSlice: id present but non-integer → handler receives null id" {
    // A non-integer id (e.g. a string "abc") must be treated as fire-and-forget:
    // the handler receives null, not a crash or error. The id field is silently
    // ignored for unrecognised types.
    var bridge = try makeTestBridge();
    defer bridge.deinit();
    try bridge.addHandler("ping", DispatchProbe.record);

    DispatchProbe.reset();
    try bridge.dispatchSlice(
        \\{"method":"ping","id":"abc"}
    );
    try std.testing.expect(DispatchProbe.fired);
    try std.testing.expectEqual(@as(?i64, null), DispatchProbe.last_id);

    // Also test id as a JSON object (another non-integer type).
    DispatchProbe.reset();
    try bridge.dispatchSlice(
        \\{"method":"ping","id":{"nested":true}}
    );
    try std.testing.expect(DispatchProbe.fired);
    try std.testing.expectEqual(@as(?i64, null), DispatchProbe.last_id);

    // And id as a boolean.
    DispatchProbe.reset();
    try bridge.dispatchSlice(
        \\{"method":"ping","id":true}
    );
    try std.testing.expect(DispatchProbe.fired);
    try std.testing.expectEqual(@as(?i64, null), DispatchProbe.last_id);
}

test "dispatchSlice: id present and handler calls buildResolveJS → correct JS string" {
    // Verify the full resolve path: handler receives a non-null id and uses it
    // to build the correct __resolve JS string. We test `buildResolveJS` directly
    // (the pure Zig path) to avoid ObjC/WebKit in the headless suite — this is
    // sufficient since `resolve` itself is already covered by its own test.
    const ResolveProbe = struct {
        var got_id: ?i64 = null;
        var resolved_js: [128]u8 = undefined;
        var resolved_js_len: usize = 0;

        fn handler(b: *Bridge, _: std.json.Value, id: ?i64) void {
            got_id = id;
            if (id) |real_id| {
                // Build the resolve JS string (pure Zig, headless-safe).
                const js = Bridge.buildResolveJS(real_id, "42", b.allocator) catch return;
                defer b.allocator.free(js);
                const n = @min(js.len, resolved_js.len);
                @memcpy(resolved_js[0..n], js[0..n]);
                resolved_js_len = n;
            }
        }
    };
    ResolveProbe.got_id = null;
    ResolveProbe.resolved_js_len = 0;

    var bridge = try makeTestBridge();
    defer bridge.deinit();
    try bridge.addHandler("echo", ResolveProbe.handler);

    try bridge.dispatchSlice(
        \\{"method":"echo","params":"hello","id":5}
    );
    try std.testing.expectEqual(@as(?i64, 5), ResolveProbe.got_id);
    try std.testing.expectEqualStrings(
        "__resolve(5, 42)",
        ResolveProbe.resolved_js[0..ResolveProbe.resolved_js_len],
    );
}

test "registerHandler: comptime method routes correctly" {
    // registerHandler is a thin comptime wrapper over addHandler. Verify it
    // registers and routes identically to addHandler.
    var bridge = try makeTestBridge();
    defer bridge.deinit();

    const Probe = struct {
        var fired: bool = false;
        fn handler(_: *Bridge, _: std.json.Value, _: ?i64) void {
            fired = true;
        }
    };
    Probe.fired = false;

    try bridge.registerHandler("comptime_method", Probe.handler);

    try bridge.dispatchSlice(
        \\{"method":"comptime_method"}
    );
    try std.testing.expect(Probe.fired);
}

test "registerHandler: comptime method with id passed through" {
    // Confirm registerHandler-registered handlers receive the id correctly.
    var bridge = try makeTestBridge();
    defer bridge.deinit();

    const Probe = struct {
        var got_id: ?i64 = null;
        fn handler(_: *Bridge, _: std.json.Value, id: ?i64) void {
            got_id = id;
        }
    };
    Probe.got_id = null;

    try bridge.registerHandler("rpc_call", Probe.handler);

    try bridge.dispatchSlice(
        \\{"method":"rpc_call","id":42}
    );
    try std.testing.expectEqual(@as(?i64, 42), Probe.got_id);
}

test "Bridge exposes registerHandler as a public decl" {
    try std.testing.expect(@hasDecl(Bridge, "registerHandler"));
    // Return type is Allocator.Error!void — same as addHandler.
    const Ret = @typeInfo(@TypeOf(Bridge.registerHandler)).@"fn".return_type.?;
    try std.testing.expectEqual(std.mem.Allocator.Error!void, Ret);
}

test "dispatchSlice: id present as zero passes 0 to handler, not null" {
    // Zero is a valid correlation id. A naive `if (id_val == 0)` guard would
    // collapse it to null — this test pins that `id:0` arrives as `?i64 = 0`,
    // not as `null`.
    var bridge = try makeTestBridge();
    defer bridge.deinit();
    try bridge.addHandler("zero_id", DispatchProbe.record);

    DispatchProbe.reset();
    try bridge.dispatchSlice(
        \\{"method":"zero_id","id":0}
    );
    try std.testing.expect(DispatchProbe.fired);
    try std.testing.expectEqual(@as(?i64, 0), DispatchProbe.last_id);
}

test "dispatchSlice: id present as JSON null → handler receives null id" {
    // JSON `"id":null` is an explicit null — not an integer, so the id extraction
    // switch falls through to the `else => null` arm and the handler sees no id.
    var bridge = try makeTestBridge();
    defer bridge.deinit();
    try bridge.addHandler("null_id", DispatchProbe.record);

    DispatchProbe.reset();
    try bridge.dispatchSlice(
        \\{"method":"null_id","id":null}
    );
    try std.testing.expect(DispatchProbe.fired);
    try std.testing.expectEqual(@as(?i64, null), DispatchProbe.last_id);
}

test "registerHandler: multiple comptime methods route to their respective handlers only" {
    // The single-method registerHandler tests do not prove the hashmap lookup
    // discriminates. Register three methods via registerHandler and confirm that
    // dispatching each method fires exactly that handler and no other.
    const MultiReg = struct {
        var alpha: bool = false;
        var beta: bool = false;
        var gamma: bool = false;

        fn hAlpha(_: *Bridge, _: std.json.Value, _: ?i64) void {
            alpha = true;
        }
        fn hBeta(_: *Bridge, _: std.json.Value, _: ?i64) void {
            beta = true;
        }
        fn hGamma(_: *Bridge, _: std.json.Value, _: ?i64) void {
            gamma = true;
        }
    };
    MultiReg.alpha = false;
    MultiReg.beta = false;
    MultiReg.gamma = false;

    var bridge = try makeTestBridge();
    defer bridge.deinit();
    try bridge.registerHandler("alpha", MultiReg.hAlpha);
    try bridge.registerHandler("beta", MultiReg.hBeta);
    try bridge.registerHandler("gamma", MultiReg.hGamma);

    // Route to "beta" only.
    try bridge.dispatchSlice(
        \\{"method":"beta"}
    );
    try std.testing.expect(!MultiReg.alpha);
    try std.testing.expect(MultiReg.beta);
    try std.testing.expect(!MultiReg.gamma);

    // Route to "gamma"; alpha still false, beta still true.
    try bridge.dispatchSlice(
        \\{"method":"gamma"}
    );
    try std.testing.expect(!MultiReg.alpha);
    try std.testing.expect(MultiReg.gamma);

    // Route to "alpha"; all three now true.
    try bridge.dispatchSlice(
        \\{"method":"alpha"}
    );
    try std.testing.expect(MultiReg.alpha);

    // An unregistered name still returns UnknownMethod, nothing extra fires.
    try std.testing.expectError(DispatchError.UnknownMethod, bridge.dispatchSlice(
        \\{"method":"delta"}
    ));
}

// --- API-surface / type contract (compile-time) ---

test "Error set includes ClassNotFound and the Allocator errors" {
    // M2.3 widened Error with Allocator.Error (init builds the dispatch map),
    // so it is no longer a singleton. Assert both the original member and the
    // Allocator member are coercible into the set.
    const class_not_found: Error = error.ClassNotFound;
    const oom: Error = error.OutOfMemory;
    try std.testing.expectEqual(Error.ClassNotFound, class_not_found);
    try std.testing.expectEqual(Error.OutOfMemory, oom);
}

test "Bridge exposes the documented public API surface" {
    try std.testing.expect(@hasField(Bridge, "handler"));
    try std.testing.expect(@hasField(Bridge, "ucc"));
    try std.testing.expect(@hasField(Bridge, "webview"));
    try std.testing.expect(@hasField(Bridge, "on_message"));
    try std.testing.expect(@hasField(Bridge, "allocator"));
    try std.testing.expect(@hasField(Bridge, "dispatch"));
    try std.testing.expectEqual(objc.Object, @FieldType(Bridge, "handler"));
    try std.testing.expectEqual(objc.Object, @FieldType(Bridge, "ucc"));
    try std.testing.expectEqual(objc.Object, @FieldType(Bridge, "webview"));
    try std.testing.expectEqual(OnMessage, @FieldType(Bridge, "on_message"));
    try std.testing.expectEqual(std.mem.Allocator, @FieldType(Bridge, "allocator"));
    try std.testing.expectEqual(DispatchTable, @FieldType(Bridge, "dispatch"));

    const InitRet = @typeInfo(@TypeOf(Bridge.init)).@"fn".return_type.?;
    try std.testing.expectEqual(Error!Bridge, InitRet);

    const AttachRet = @typeInfo(@TypeOf(Bridge.attach)).@"fn".return_type.?;
    try std.testing.expectEqual(Error!void, AttachRet);

    // addHandler is private; only registerHandler is the public registration API.
    // (From within the same file @hasDecl sees private decls too, so we only
    //  assert the public one here.)

    const RegRet = @typeInfo(@TypeOf(Bridge.registerHandler)).@"fn".return_type.?;
    try std.testing.expectEqual(std.mem.Allocator.Error!void, RegRet);

    const DispatchRet = @typeInfo(@TypeOf(Bridge.dispatchSlice)).@"fn".return_type.?;
    try std.testing.expectEqual(DispatchError!void, DispatchRet);

    try std.testing.expectEqual(void, @typeInfo(@TypeOf(Bridge.evaluate)).@"fn".return_type.?);
    try std.testing.expectEqual(
        std.mem.Allocator.Error!void,
        @typeInfo(@TypeOf(Bridge.resolve)).@"fn".return_type.?,
    );
    try std.testing.expectEqual(void, @typeInfo(@TypeOf(Bridge.handleMessage)).@"fn".return_type.?);
    try std.testing.expectEqual(void, @typeInfo(@TypeOf(Bridge.deinit)).@"fn".return_type.?);
}

test "required Foundation/WebKit classes resolve in the runtime" {
    try std.testing.expect(objc.getClass("NSObject") != null);
    try std.testing.expect(objc.getClass("NSString") != null);
    try std.testing.expect(objc.getClass("WKUserContentController") != null);
    try std.testing.expect(objc.getClass("WKScriptMessage") != null);
}

test "WKUserContentController responds to the selectors the Bridge sends" {
    const ucc = objc.getClass("WKUserContentController").?;
    try std.testing.expect(ucc.msgSend(
        bool,
        "instancesRespondToSelector:",
        .{objc.sel("addScriptMessageHandler:name:").value},
    ));
    try std.testing.expect(ucc.msgSend(
        bool,
        "instancesRespondToSelector:",
        .{objc.sel("removeScriptMessageHandlerForName:").value},
    ));
}

test {
    std.testing.refAllDecls(@This());
}
