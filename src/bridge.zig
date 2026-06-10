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
//! reachable in the IMP and handed to a `on_message` callback. The full
//! NSDictionary -> Zig extraction + std.json parse + dispatch table is M2.3 —
//! `handleMessage` below is the deliberately-minimal seam M2.3 fleshes out.
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
};

/// A reply path the IMP hands the raw message `body` to. The body is a borrowed,
/// autoreleased Objective-C object (NSString / NSDictionary / NSNumber / ...)
/// owned by WebKit for the duration of the call — the callback must NOT release
/// it and must NOT retain it past the call without taking its own +1. M2.3
/// replaces the default callback with the JSON-parse + dispatch path.
pub const OnMessage = *const fn (bridge: *Bridge, body: objc.Object) void;

/// Default `on_message`: log that a message arrived and its Objective-C class.
/// M2.3 swaps in real extraction; until then this proves the IMP reached the
/// body without assuming any particular body shape.
fn logMessage(bridge: *Bridge, body: objc.Object) void {
    _ = bridge;
    if (body.value == null) {
        std.log.info("wkz bridge: received message with null body", .{});
        return;
    }
    const class_name = body.getClassName();
    std.log.info("wkz bridge: received message (body class: {s})", .{class_name});
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

    /// Where the IMP routes each incoming message body. M2.3 replaces this.
    on_message: OnMessage,

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
    pub fn init(ucc: objc.Object) Error!Bridge {
        const handler_class = try handlerClass();

        // +1 handler instance owned by this Bridge (released in deinit).
        const handler = handler_class.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "init", .{});

        return .{
            .handler = handler,
            .ucc = ucc,
            .on_message = logMessage,
        };
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

    /// Deregister the handler from the user content controller and release the
    /// owned `+1` handler instance. After this no message can fire against the
    /// (now potentially dangling) context pointer. Must be called on the main
    /// thread.
    pub fn deinit(self: *Bridge) void {
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
        .on_message = logMessage,
    };

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
    };
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

// --- API-surface / type contract (compile-time) ---

test "Error set is exactly {ClassNotFound}" {
    const fields = @typeInfo(Error).error_set.?;
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("ClassNotFound", fields[0].name);
}

test "Bridge exposes the documented public API surface" {
    try std.testing.expect(@hasField(Bridge, "handler"));
    try std.testing.expect(@hasField(Bridge, "ucc"));
    try std.testing.expect(@hasField(Bridge, "on_message"));
    try std.testing.expectEqual(objc.Object, @FieldType(Bridge, "handler"));
    try std.testing.expectEqual(objc.Object, @FieldType(Bridge, "ucc"));
    try std.testing.expectEqual(OnMessage, @FieldType(Bridge, "on_message"));

    const InitRet = @typeInfo(@TypeOf(Bridge.init)).@"fn".return_type.?;
    try std.testing.expectEqual(Error!Bridge, InitRet);

    const AttachRet = @typeInfo(@TypeOf(Bridge.attach)).@"fn".return_type.?;
    try std.testing.expectEqual(Error!void, AttachRet);

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
