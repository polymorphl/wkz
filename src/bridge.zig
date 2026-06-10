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
//! on `dispatchSlice`. Robustness ("logs, never crashes") is formalized in M2.4;
//! here malformed input surfaces as a clean Zig error (no panic) that the
//! `on_message` boundary logs.
//!
//! Main thread only. No ARC: see the ownership notes on `Bridge`.

const std = @import("std");
const objc = @import("objc");

const c = objc.c;

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
    /// The body bytes did not parse as JSON, or the top-level value was not a
    /// JSON object. Either way there is no message to dispatch.
    InvalidMessage,
    /// The parsed object had no `method` string (missing, or not a string).
    MissingMethod,
    /// The `method` string did not match any registered handler.
    UnknownMethod,
} || std.mem.Allocator.Error;

/// A registered Zig handler for one `method`. Receives the owning `*Bridge` and
/// the parsed `params` JSON value (`.null` when the message carried no `params`).
///
/// The `params` `Value` borrows the JSON parse arena that owns it; it is valid
/// only for the duration of this call and must NOT be retained past return (copy
/// out anything needed longer). M2.3 keeps the signature minimal but
/// forward-looking: the typed request/response correlation (`id` -> `__resolve`)
/// is layered on in M3.1/M3.2 without changing this runtime seam.
pub const Handler = *const fn (bridge: *Bridge, params: std.json.Value) void;

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
    if (body.value == null) {
        std.log.warn("wkz bridge: received message with null body", .{});
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
    const utf8 = body.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse {
        std.log.warn("wkz bridge: received message with un-decodable body", .{});
        return;
    };
    const bytes = std.mem.span(utf8);

    bridge.dispatchSlice(bytes) catch |err| {
        std.log.warn("wkz bridge: dropped message ({s})", .{@errorName(err)});
    };
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

    /// Where the IMP routes each incoming message body. Defaults to
    /// `dispatchMessage` (extract + parse + dispatch); tests may swap a probe.
    on_message: OnMessage,

    /// Allocator used for JSON parsing (the parse arena) and any per-message
    /// heap. Borrowed from the caller via `init`; `Bridge` does not own it.
    allocator: std.mem.Allocator,

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
    /// IMPORTANT: the IMP recovers the context by the *address* stored in the
    /// handler's ivar. `init` does NOT write that ivar — it cannot know the final
    /// address of a by-value return, which the caller will move into its own
    /// storage. The caller MUST place the returned `Bridge` at a stable address
    /// (a long-lived local or field that outlives the webview) and then call
    /// `attach(self: *Bridge)` exactly once. See `attach`.
    ///
    /// `allocator` is borrowed (not owned) and used for JSON parsing and the
    /// dispatch table's backing storage; the map is built here and freed by
    /// `deinit`. On the error path the +1 handler is released (errdefer) so
    /// nothing leaks.
    pub fn init(allocator: std.mem.Allocator, ucc: objc.Object) Error!Bridge {
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
    /// This is the M2.3 runtime registration seam. The comptime-typed
    /// `registerHandler(comptime method, fn)` public API (which derives the
    /// param/return types and wires the `__resolve` response path) is M3.2 and
    /// layers on top of this table without changing it.
    pub fn addHandler(self: *Bridge, method: []const u8, handler: Handler) std.mem.Allocator.Error!void {
        // HashMap.put (hash_map.zig:322): put(self, key, value) !void. Does not
        // copy the key (StringHashMap keys are caller-managed).
        try self.dispatch.put(method, handler);
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
        // parseFromSlice (json/static.zig:71): (T, allocator, s, options)
        // !Parsed(T). Treat any parse failure as InvalidMessage (hostile input).
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

        // `id` (optional): not read in M2.3 (no reply path yet). M3.1/M3.2 will
        // read it here to correlate the `__resolve(id, result)` response.

        // `params` (optional, arbitrary JSON): default to .null when absent so
        // the handler always receives a well-formed Value.
        const params: std.json.Value = root.get("params") orelse .null;

        // Look the method up in the dispatch table. get (hash_map.zig:367)
        // returns ?Handler.
        const handler = self.dispatch.get(method) orelse return DispatchError.UnknownMethod;

        handler(self, params);
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
        // No context wired (e.g. handler fired before attach()): nothing to do.
        std.log.warn("wkz bridge: message with no context attached", .{});
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
    // (no attach() ran). If the IMP fired in that window (e.g. a message arrived
    // before attach), it must hit the `ctx.value == null` guard and return — NOT
    // @ptrCast a null and dereference it. We invoke the IMP directly against such
    // an unwired handler; reaching the end without crashing IS the assertion. The
    // message arg is nil too: the guard returns before -body is ever sent, so a
    // nil message can never be touched on this path.
    const cls = try handlerClass();
    const handler = cls.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer handler.msgSend(void, "release", .{});

    // Confirm the precondition: the ivar really is null on a fresh instance.
    try std.testing.expect(handler.getInstanceVariable(ctx_ivar_name).value == null);

    // Must return early via the guard; if it instead dereferenced the null ctx
    // or sent -body to the nil message, this would crash the test process.
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
    }

    /// Handler that records it ran and copies a `params.name` string (if the
    /// params is an object with a string `name`) into a static buffer. We copy
    /// because the params Value borrows the parse arena, which is freed once
    /// dispatchSlice returns.
    fn record(bridge: *Bridge, params: std.json.Value) void {
        _ = bridge;
        fired = true;
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
        fn h(_: *Bridge, _: std.json.Value) void {
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
    fn record(_: *Bridge, params: std.json.Value) void {
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
    fn record(_: *Bridge, params: std.json.Value) void {
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
        fn h1(_: *Bridge, _: std.json.Value) void {
            one = true;
        }
        fn h2(_: *Bridge, _: std.json.Value) void {
            two = true;
        }
        fn h3(_: *Bridge, _: std.json.Value) void {
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
        fn h(_: *Bridge, _: std.json.Value) void {}
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
    try std.testing.expect(@hasField(Bridge, "on_message"));
    try std.testing.expect(@hasField(Bridge, "allocator"));
    try std.testing.expect(@hasField(Bridge, "dispatch"));
    try std.testing.expectEqual(objc.Object, @FieldType(Bridge, "handler"));
    try std.testing.expectEqual(objc.Object, @FieldType(Bridge, "ucc"));
    try std.testing.expectEqual(OnMessage, @FieldType(Bridge, "on_message"));
    try std.testing.expectEqual(std.mem.Allocator, @FieldType(Bridge, "allocator"));
    try std.testing.expectEqual(DispatchTable, @FieldType(Bridge, "dispatch"));

    const InitRet = @typeInfo(@TypeOf(Bridge.init)).@"fn".return_type.?;
    try std.testing.expectEqual(Error!Bridge, InitRet);

    const AttachRet = @typeInfo(@TypeOf(Bridge.attach)).@"fn".return_type.?;
    try std.testing.expectEqual(Error!void, AttachRet);

    const AddRet = @typeInfo(@TypeOf(Bridge.addHandler)).@"fn".return_type.?;
    try std.testing.expectEqual(std.mem.Allocator.Error!void, AddRet);

    const DispatchRet = @typeInfo(@TypeOf(Bridge.dispatchSlice)).@"fn".return_type.?;
    try std.testing.expectEqual(DispatchError!void, DispatchRet);

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
