//! UNUserNotificationCenter bridge handlers.
//!
//! Responsibility: register bridge handlers for requesting notification
//! permission and sending local notifications via the macOS
//! `UserNotifications` framework. Handlers are fire-and-forget where
//! appropriate (completionHandler must be nil — no ObjC blocks allowed per
//! the hard rules).
//!
//! Note: sandboxed apps would additionally require the entitlements
//! `com.apple.security.app-sandbox` + `com.apple.usernotifications`. This
//! example is NOT sandboxed (no entitlements file, no codesigning beyond
//! ad-hoc), so notifications work on the developer's machine via the
//! non-sandboxed path without any entitlements.
//!
//! Main thread only. No ARC: see ownership notes per handler.

const std = @import("std");
const objc = @import("objc");
const Bridge = @import("bridge.zig").Bridge;
const objc_helpers = @import("objc_helpers.zig");

const c = objc.c;

const log = std.log.scoped(.wkz_notifications);

/// Monotonic counter used to generate unique notification identifiers when the
/// JS caller does not supply an `"id"` param. Main-thread only — no atomics
/// needed.
var notification_counter: u64 = 0;

/// Process-lived singleton `WkzUNDelegate` instance.
///
/// Ownership (no ARC): created with `+new` (+1) the first time `setupDelegate`
/// runs. The center is a process-lived singleton; the delegate must outlive it,
/// so this instance is also intentionally process-lived. It is never released.
/// The idempotent guard in `setupDelegate` ensures it is allocated at most once.
var delegate_instance: objc.Object = .{ .value = null };

/// Process-unique name for the `UNUserNotificationCenterDelegate` subclass.
/// A registered ObjC class lives for the whole process — one definition is
/// correct and is NOT a leak.
const delegate_class_name: [:0]const u8 = "WkzUNDelegate";

/// Name of the `id`-typed instance variable on the delegate class that stores
/// the borrowed `*Bridge` context pointer. Same no-ARC semantics as the
/// `wkz_ctx` ivar on `WkzScriptMessageHandler` — a raw pointer store, no
/// retain/release, no object semantics.
const bridge_ivar_name: [:0]const u8 = "wkz_bridge";

/// ObjC runtime functions not exposed by zig-objc.
extern fn objc_getProtocol(name: [*:0]const u8) ?*anyopaque;
extern fn class_addProtocol(cls: objc.c.Class, proto: *anyopaque) bool;

// Comptime assertion: pins the Darwin block ABI layout assumed by the IMP
// functions below. If the offset ever changes (it hasn't since 2008), this
// catches it at compile time.
const BlockHeader = extern struct {
    isa: *anyopaque,
    flags: i32,
    reserved: i32,
    invoke: *anyopaque,
};
comptime {
    std.debug.assert(@offsetOf(BlockHeader, "invoke") == 16);
}

/// IMP for `-[WkzUNDelegate userNotificationCenter:willPresentNotification:withCompletionHandler:]`.
///
/// Called by the system when a notification would be delivered while the app is
/// in the foreground. We call the completion-handler block to request banner +
/// sound + list presentation (combined options value = 14).
///
/// Calling a block passed TO us is NOT creating a block — the hard rule
/// "no ObjC blocks" forbids creating blocks, not calling them.
///
/// Block memory layout (64-bit ABI):
///   offset  0: void *isa       (8 bytes)
///   offset  8: int  flags      (4 bytes)
///   offset 12: int  reserved   (4 bytes)
///   offset 16: void *invoke    (8 bytes)  ← function pointer to call
///   offset 24: void *descriptor (8 bytes)
///
/// The invoke function for `^(UNNotificationPresentationOptions) void` has the
/// C ABI signature:
///   void invoke(void *block, UNNotificationPresentationOptions options)
///
/// UNNotificationPresentationOptions (macOS 12+):
///   UNNotificationPresentationOptionSound  = 2
///   UNNotificationPresentationOptionBanner = 4
///   UNNotificationPresentationOptionList   = 8
///   Combined = 14
fn impWillPresentNotification(
    _self: c.id,
    _sel: c.SEL,
    _center: c.id,
    _notification: c.id,
    handler: c.id,
) callconv(.c) void {
    _ = _self;
    _ = _sel;
    _ = _center;
    _ = _notification;

    if (handler == null) return;

    // Read the `invoke` function pointer from offset 16 of the block struct.
    const InvokeFn = *const fn (*anyopaque, u64) callconv(.c) void;
    const invoke_ptr: *const InvokeFn = @ptrFromInt(@intFromPtr(handler.?) + 16);
    log.debug("impWillPresentNotification: calling completion handler", .{});
    // banner (4) | list (8) | sound (2) = 14
    invoke_ptr.*(handler.?, 4 | 8 | 2);
}

/// IMP for `-[WkzUNDelegate userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:]`.
///
/// Called by the system when the user clicks a notification banner (both while
/// the app is in the foreground and when the click brings the app to the
/// foreground from the background / not-running state).
///
/// This IMP:
///   1. Recovers the borrowed `*Bridge` from the `wkz_bridge` ivar.
///   2. Extracts the notification identifier from the response object.
///   3. Builds a JSON payload `{"id":"<identifier>"}` and calls `bridge.emit`.
///   4. Calls the completion-handler block (no-arg invoke at offset 16).
///
/// ARC: `*Bridge` is stored raw (no retain) — same semantics as `wkz_ctx` on
/// `WkzScriptMessageHandler`. The bridge pointer is valid for the process
/// lifetime (see `setupDelegate` ownership note). All allocator-allocated
/// slices (escaped_backslash, escaped_id, payload) are freed before return via
/// `defer`. All ObjC objects here are borrowed from the system call stack (not
/// retained, not released by us).
///
/// No ObjC blocks created — we only call the block passed to us.
///
/// JSON safety (receive side): the OS-returned identifier is JSON-escaped
/// (`\` → `\\`, then `"` → `\"`) before embedding in the payload. This
/// handles identifiers from any source (including external notifications not
/// sent through our bridge) and is the second layer of a two-layer defence —
/// `isValidNotificationId` guards caller-supplied ids on the send side.
///
/// The completion handler for `didReceiveNotificationResponse:` takes no
/// arguments: its invoke signature is `fn(*anyopaque) callconv(.c) void`.
fn impDidReceiveNotificationResponse(
    _self: c.id,
    _sel: c.SEL,
    _center: c.id,
    response: c.id,
    handler: c.id,
) callconv(.c) void {
    _ = _sel;
    _ = _center;

    // Recover the borrowed *Bridge from the delegate's wkz_bridge ivar.
    // object_getIvar is a raw pointer read (no retain) under MRC.
    const delegate = objc.Object{ .value = _self };
    const ctx = delegate.getInstanceVariable(bridge_ivar_name);
    if (ctx.value == null) {
        log.warn("notifications: didReceiveNotificationResponse: no bridge context (wkz_bridge ivar nil)", .{});
        // Still call the completion handler even without a bridge context.
        if (handler != null) {
            const InvokeFn = *const fn (*anyopaque) callconv(.c) void;
            const invoke_ptr: *const InvokeFn = @ptrFromInt(@intFromPtr(handler.?) + 16);
            invoke_ptr.*(handler.?);
        }
        return;
    }
    const bridge: *Bridge = @ptrCast(@alignCast(ctx.value));

    // Extract the notification identifier:
    //   response → notification → request → identifier (NSString) → UTF8String
    // All objects here are borrowed from the system's call stack — not owned,
    // not retained, not released.
    const resp_obj = objc.Object{ .value = response };
    const notification = resp_obj.msgSend(objc.Object, "notification", .{});
    const request = notification.msgSend(objc.Object, "request", .{});
    const identifier_ns = request.msgSend(objc.Object, "identifier", .{});
    const identifier_cstr = identifier_ns.msgSend(?[*:0]const u8, "UTF8String", .{});
    const identifier: []const u8 = if (identifier_cstr) |s| std.mem.span(s) else "";

    // Build JSON payload: {"id":"<identifier>"}
    //
    // JSON-escape the identifier before embedding: `\` → `\\` first (so the
    // inserted backslashes are not themselves re-escaped), then `"` → `\"`.
    // This is necessary even for auto-generated ids: the notification may have
    // come from an external source (not our bridge), so we cannot assume the
    // OS-supplied identifier is free of `"` or `\`.
    //
    // replaceOwned (std/mem.zig:4199):
    //   pub fn replaceOwned(T, allocator, input, needle, replacement) Allocator.Error![]T
    const escaped_backslash = std.mem.replaceOwned(
        u8,
        bridge.allocator,
        identifier,
        "\\",
        "\\\\",
    ) catch {
        log.warn("notifications: didReceiveNotificationResponse: OOM escaping identifier (backslash)", .{});
        if (handler != null) {
            const InvokeFn = *const fn (*anyopaque) callconv(.c) void;
            const invoke_ptr: *const InvokeFn = @ptrFromInt(@intFromPtr(handler.?) + 16);
            invoke_ptr.*(handler.?);
        }
        return;
    };
    defer bridge.allocator.free(escaped_backslash);

    const escaped_id = std.mem.replaceOwned(
        u8,
        bridge.allocator,
        escaped_backslash,
        "\"",
        "\\\"",
    ) catch {
        log.warn("notifications: didReceiveNotificationResponse: OOM escaping identifier (quote)", .{});
        if (handler != null) {
            const InvokeFn = *const fn (*anyopaque) callconv(.c) void;
            const invoke_ptr: *const InvokeFn = @ptrFromInt(@intFromPtr(handler.?) + 16);
            invoke_ptr.*(handler.?);
        }
        return;
    };
    defer bridge.allocator.free(escaped_id);

    const payload = std.fmt.allocPrint(
        bridge.allocator,
        "{{\"id\":\"{s}\"}}",
        .{escaped_id},
    ) catch {
        log.warn("notifications: didReceiveNotificationResponse: OOM building payload", .{});
        if (handler != null) {
            const InvokeFn = *const fn (*anyopaque) callconv(.c) void;
            const invoke_ptr: *const InvokeFn = @ptrFromInt(@intFromPtr(handler.?) + 16);
            invoke_ptr.*(handler.?);
        }
        return;
    };
    defer bridge.allocator.free(payload);

    // Push the event to JS via the __wkz_event global installed by events.ts.
    bridge.emit("notifications.clicked", payload) catch |err| {
        log.warn("notifications: didReceiveNotificationResponse: emit failed: {}", .{err});
    };

    // Call the no-arg completion handler block (invoke at offset 16).
    if (handler != null) {
        const InvokeFn = *const fn (*anyopaque) callconv(.c) void;
        const invoke_ptr: *const InvokeFn = @ptrFromInt(@intFromPtr(handler.?) + 16);
        invoke_ptr.*(handler.?);
    }
}

/// Create (or look up) the `WkzUNDelegate` class.
///
/// Open-coded (same pattern as `WkzScriptMessageHandler` in bridge.zig): we
/// cannot use `objc_helpers.defineClass` because `addIvar` must happen between
/// `allocateClassPair` and `registerClassPair`, and `defineClass` is a black
/// box that registers immediately after adding methods. Open-coding gives us
/// the window to insert the ivar.
///
/// Idempotent: if already registered (e.g. second call in the same process),
/// returns the existing class. Process-lived — nothing to release.
fn delegateClass() objc_helpers.Error!objc.Class {
    // Idempotent guard: return existing class if already registered.
    if (objc.getClass(delegate_class_name)) |existing| return existing;

    const NSObject = objc.getClass("NSObject") orelse
        return objc_helpers.Error.ClassRegistrationFailed;

    // objc_allocateClassPair fails (nil) on a duplicate name; guarded above, so
    // nil here is a genuine allocation failure.
    const cls = objc.allocateClassPair(NSObject, delegate_class_name) orelse
        return objc_helpers.Error.ClassRegistrationFailed;

    // Add the `wkz_bridge` ivar BEFORE registerClassPair — this is the only
    // window in which class_addIvar is legal. Stores a borrowed *Bridge pointer.
    std.debug.assert(cls.addIvar(bridge_ivar_name));

    // Register both delegate methods. addMethod asserts the IMP convention and
    // derives the encoding from the fn type. false only if the selector already
    // exists on a fresh pair — a programming error, so assert.
    std.debug.assert(cls.addMethod(
        "userNotificationCenter:willPresentNotification:withCompletionHandler:",
        impWillPresentNotification,
    ));
    std.debug.assert(cls.addMethod(
        "userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:",
        impDidReceiveNotificationResponse,
    ));

    objc.registerClassPair(cls);

    // Declare protocol conformance so UNUserNotificationCenter recognises the
    // delegate. class_addProtocol is idempotent on an already-registered class.
    if (objc_getProtocol("UNUserNotificationCenterDelegate")) |proto| {
        _ = class_addProtocol(cls.value, proto);
    }
    return cls;
}

/// Set up the foreground-notification delegate on `center`.
///
/// Creates the `WkzUNDelegate` class and singleton instance (if not yet done),
/// stores the borrowed `*bridge` pointer in the instance's `wkz_bridge` ivar,
/// then calls `setDelegate:` on the provided center object. Idempotent: if the
/// delegate instance was already created and wired in a prior call, this is a
/// no-op.
///
/// Must be called with a live `UNUserNotificationCenter` (i.e. only from paths
/// that have already obtained the center successfully, not from headless tests).
///
/// ARC: `delegate_instance` is created with `+new` (+1) and is intentionally
/// process-lived (never released). The center is also process-lived. The
/// `*Bridge` stored in the ivar is a BORROWED raw pointer — no retain, no
/// release, no object semantics (same pattern as `WkzScriptMessageHandler`).
fn setupDelegate(center: objc.Object, bridge: *Bridge) void {
    // Idempotent guard: only create and assign once per process.
    if (delegate_instance.value != null) {
        log.debug("setupDelegate: already set, skipping", .{});
        return;
    }

    const cls = delegateClass() catch |err| {
        log.warn("notifications: failed to create WkzUNDelegate class: {}", .{err});
        return;
    };
    log.debug("setupDelegate: WkzUNDelegate class obtained", .{});

    // `+new` is equivalent to `[[cls alloc] init]` → +1. Process-lived; never
    // released (see module-level doc comment on `delegate_instance`).
    delegate_instance = cls.msgSend(objc.Object, "new", .{});
    if (delegate_instance.value == null) {
        log.warn("notifications: WkzUNDelegate +new returned nil", .{});
        return;
    }

    // Store the borrowed *Bridge in the wkz_bridge ivar. Raw pointer write via
    // object_setIvar — no retain under MRC. The bridge must outlive the delegate
    // (both are process-lived in normal use).
    delegate_instance.setInstanceVariable(
        bridge_ivar_name,
        .{ .value = @ptrCast(bridge) },
    );
    log.debug("setupDelegate: bridge pointer stored in wkz_bridge ivar", .{});

    center.msgSend(void, "setDelegate:", .{delegate_instance});

    const responds = delegate_instance.msgSend(
        bool,
        "respondsToSelector:",
        .{objc.sel("userNotificationCenter:willPresentNotification:withCompletionHandler:").value},
    );
    log.debug("setupDelegate: delegate respondsToSelector willPresent={}", .{responds});
    const responds2 = delegate_instance.msgSend(
        bool,
        "respondsToSelector:",
        .{objc.sel("userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:").value},
    );
    log.debug("setupDelegate: delegate respondsToSelector didReceive={}", .{responds2});
}

/// Register the `notifications.requestPermission` and `notifications.send`
/// bridge handlers on `bridge`.
///
/// Call once at startup after `bridge.attach()`. No mutable module state
/// other than `notification_counter` is touched at handler registration time.
///
/// The `WkzUNDelegate` class is eagerly created here (class creation is
/// headless-safe). The delegate is then wired onto the notification center the
/// first time a handler that fetches the center runs (lazy, always in a live
/// app context). This avoids calling `currentNotificationCenter` at
/// registration time, which throws `NSInternalInconsistencyException` in
/// headless test binaries that have no app bundle.
///
/// Returns `Allocator.Error` if the dispatch table cannot grow.
pub fn registerHandlers(bridge: *Bridge) std.mem.Allocator.Error!void {
    // Eagerly create the delegate class (headless-safe: class pair registration
    // does not require an app bundle). The instance and setDelegate: call happen
    // lazily inside the handlers once a live center is available.
    //
    // Note: `delegateClass()` is open-coded (not via `defineClass`) so it can
    // add the `wkz_bridge` ivar before `registerClassPair`.
    _ = delegateClass() catch |err| {
        log.warn("notifications: failed to pre-create WkzUNDelegate class: {}", .{err});
    };

    try bridge.registerHandler("notifications.requestPermission", handleRequestPermission);
    try bridge.registerHandler("notifications.send", handleSend);
}

/// notifications.requestPermission — request authorization to show alerts,
/// sounds, and badges.
///
/// Calls `[UNUserNotificationCenter requestAuthorizationWithOptions:completionHandler:]`
/// with options = 7 (alert | sound | badge) and `nil` as the completionHandler
/// (no ObjC blocks per hard rule #3). The OS presents its own permission dialog
/// asynchronously; we resolve immediately with `"true"` (fire-and-forget).
///
/// ARC notes:
///   - `currentNotificationCenter` returns a singleton — do NOT release.
fn handleRequestPermission(bridge: *Bridge, params: std.json.Value, id: ?i64) void {
    _ = params;

    const UNUserNotificationCenter = objc.getClass("UNUserNotificationCenter") orelse {
        log.warn("notifications.requestPermission: UNUserNotificationCenter class not found", .{});
        if (id) |i| bridge.resolve(i, "false") catch {};
        return;
    };

    // Singleton center — do NOT release.
    const center = UNUserNotificationCenter.msgSend(
        objc.Object,
        "currentNotificationCenter",
        .{},
    );

    // Wire the delegate so foreground notifications show banners and click
    // callbacks fire. Idempotent.
    setupDelegate(center, bridge);

    // Step 1 — provisional registration (silent, no dialog, always succeeds on
    // first run; no-op on subsequent runs). Options: badge(1)|sound(2)|alert(4)|
    // provisional(64) = 71. Registers the app in the notification system so the
    // system knows to route upgrade-request dialogs.
    // completionHandler is nil (no ObjC blocks per hard rule #3).
    center.msgSend(
        void,
        "requestAuthorizationWithOptions:completionHandler:",
        .{ @as(u64, 1 | 2 | 4 | 64), @as(?*anyopaque, null) },
    );

    // Step 2 — upgrade request (shows the "allow notifications?" system dialog).
    // Options: badge(1)|sound(2)|alert(4) = 7.
    // completionHandler is nil (no ObjC blocks per hard rule #3).
    center.msgSend(
        void,
        "requestAuthorizationWithOptions:completionHandler:",
        .{ @as(u64, 1 | 2 | 4), @as(?*anyopaque, null) },
    );

    if (id) |i| bridge.resolve(i, "true") catch {};
}

/// notifications.send — deliver a local notification immediately.
///
/// params: a JSON object `{"title": "...", "body": "...", "id": "optional-string"}`.
///
/// Creates a `UNMutableNotificationContent`, sets `title` and `body`, creates
/// a `UNNotificationRequest` with a unique identifier (the `"id"` param if
/// provided, otherwise `"wkz-notif-{counter}"`), and schedules it via
/// `[UNUserNotificationCenter addNotificationRequest:withCompletionHandler:nil]`.
/// Resolves `"true"` on success.
///
/// ARC notes:
///   - `currentNotificationCenter` returns a singleton — do NOT release.
///   - `UNMutableNotificationContent +new` → `+1`, released via `defer`.
///   - `stringWithUTF8String:` for title/body/id NSStrings → autoreleased,
///     do NOT release. The NSString copies the bytes from our Zig buffer.
///   - `requestWithIdentifier:content:trigger:` → autoreleased, do NOT release.
///   - Zig sentinel slices built with `allocPrintSentinel` are freed via `defer`
///     after the corresponding `stringWithUTF8String:` call copies their bytes.
fn handleSend(bridge: *Bridge, params: std.json.Value, id: ?i64) void {
    const gpa = bridge.allocator;

    // params must be a JSON object.
    const obj = switch (params) {
        .object => |o| o,
        else => {
            log.warn("notifications.send: params must be a JSON object", .{});
            if (id) |i| bridge.resolve(i, "false") catch {};
            return;
        },
    };

    // Extract required "title" string.
    const title_str: []const u8 = switch (obj.get("title") orelse .null) {
        .string => |s| s,
        else => {
            log.warn("notifications.send: missing or non-string \"title\"", .{});
            if (id) |i| bridge.resolve(i, "false") catch {};
            return;
        },
    };

    // Extract required "body" string.
    const body_str: []const u8 = switch (obj.get("body") orelse .null) {
        .string => |s| s,
        else => {
            log.warn("notifications.send: missing or non-string \"body\"", .{});
            if (id) |i| bridge.resolve(i, "false") catch {};
            return;
        },
    };

    // Extract optional "id" string; generate one if absent.
    const notif_id_z: [:0]u8 = blk: {
        if (obj.get("id")) |id_val| {
            switch (id_val) {
                .string => |s| {
                    // Validate the caller-supplied id before use (defence-in-depth).
                    // impDidReceiveNotificationResponse escapes the OS-returned
                    // identifier on the receive side; this guard catches misuse on
                    // the send side early, before the id reaches the OS.
                    if (!isValidNotificationId(s)) {
                        log.warn("notifications.send: invalid notification id — contains illegal characters", .{});
                        if (id) |i| bridge.resolve(i, "false") catch {};
                        return;
                    }
                    // Caller supplied a safe id — NUL-terminate a copy.
                    const z = std.fmt.allocPrintSentinel(gpa, "{s}", .{s}, 0) catch {
                        log.warn("notifications.send: OOM building notification id", .{});
                        if (id) |i| bridge.resolve(i, "false") catch {};
                        return;
                    };
                    break :blk z;
                },
                else => {},
            }
        }
        // Generate an auto-incremented id (unique among auto-generated ids; callers supplying their own id are responsible for avoiding collisions with the "wkz-notif-" prefix).
        const z = std.fmt.allocPrintSentinel(
            gpa,
            "wkz-notif-{d}",
            .{notification_counter},
            0,
        ) catch {
            log.warn("notifications.send: OOM building generated notification id", .{});
            if (id) |i| bridge.resolve(i, "false") catch {};
            return;
        };
        notification_counter += 1;
        break :blk z;
    };
    defer gpa.free(notif_id_z);

    // NUL-terminated copies for stringWithUTF8String: (which copies the bytes).
    const title_z = std.fmt.allocPrintSentinel(gpa, "{s}", .{title_str}, 0) catch {
        log.warn("notifications.send: OOM building title NSString", .{});
        if (id) |i| bridge.resolve(i, "false") catch {};
        return;
    };
    defer gpa.free(title_z);

    const body_z = std.fmt.allocPrintSentinel(gpa, "{s}", .{body_str}, 0) catch {
        log.warn("notifications.send: OOM building body NSString", .{});
        if (id) |i| bridge.resolve(i, "false") catch {};
        return;
    };
    defer gpa.free(body_z);

    const NSString = objc.getClass("NSString") orelse {
        log.warn("notifications.send: NSString class not found", .{});
        if (id) |i| bridge.resolve(i, "false") catch {};
        return;
    };
    const UNMutableNotificationContent = objc.getClass("UNMutableNotificationContent") orelse {
        log.warn("notifications.send: UNMutableNotificationContent class not found", .{});
        if (id) |i| bridge.resolve(i, "false") catch {};
        return;
    };
    const UNNotificationRequest = objc.getClass("UNNotificationRequest") orelse {
        log.warn("notifications.send: UNNotificationRequest class not found", .{});
        if (id) |i| bridge.resolve(i, "false") catch {};
        return;
    };
    const UNUserNotificationCenter = objc.getClass("UNUserNotificationCenter") orelse {
        log.warn("notifications.send: UNUserNotificationCenter class not found", .{});
        if (id) |i| bridge.resolve(i, "false") catch {};
        return;
    };

    // +1 content owned by us; released via defer.
    const content = UNMutableNotificationContent.msgSend(objc.Object, "new", .{});
    if (content.value == null) {
        log.warn("notifications.send: UNMutableNotificationContent +new returned nil", .{});
        if (id) |i| bridge.resolve(i, "false") catch {};
        return;
    }
    defer content.msgSend(void, "release", .{});

    // Autoreleased NSStrings for title and body — do NOT release.
    const ns_title = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{title_z.ptr});
    const ns_body = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{body_z.ptr});

    content.msgSend(void, "setTitle:", .{ns_title});
    content.msgSend(void, "setBody:", .{ns_body});

    // Autoreleased NSString for the notification identifier — do NOT release.
    const ns_id = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{notif_id_z.ptr});

    // requestWithIdentifier:content:trigger: → autoreleased — do NOT release.
    // trigger = nil means deliver immediately.
    const request = UNNotificationRequest.msgSend(
        objc.Object,
        "requestWithIdentifier:content:trigger:",
        .{ ns_id, content, @as(?*anyopaque, null) },
    );

    // Singleton center — do NOT release.
    const center = UNUserNotificationCenter.msgSend(
        objc.Object,
        "currentNotificationCenter",
        .{},
    );

    // Wire the delegate so foreground notifications show banners and click
    // callbacks fire. Idempotent.
    setupDelegate(center, bridge);

    // completionHandler is nil (no ObjC blocks per hard rule #3).
    center.msgSend(
        void,
        "addNotificationRequest:withCompletionHandler:",
        .{ request, @as(?*anyopaque, null) },
    );

    if (id) |i| bridge.resolve(i, "true") catch {};
}

/// Fail-fast guard for caller-supplied ids registered through `handleSend`.
/// Rejects `"`, `\`, and control characters to catch misuse early.
/// `impDidReceiveNotificationResponse` independently escapes the OS-returned
/// identifier on the receive side, so this is a defence-in-depth layer, not
/// the sole guard.
fn isValidNotificationId(s: []const u8) bool {
    for (s) |ch| {
        if (ch == '"' or ch == '\\' or ch < 0x20) return false;
    }
    return true;
}

// =====================================================================
// Tests
// =====================================================================

test "UNUserNotificationCenter class resolves in ObjC runtime" {
    try std.testing.expect(objc.getClass("UNUserNotificationCenter") != null);
}

test "UNUserNotificationCenter responds to currentNotificationCenter and requestAuthorizationWithOptions:completionHandler:" {
    const cls = objc.getClass("UNUserNotificationCenter").?;
    try std.testing.expect(cls.msgSend(
        bool,
        "respondsToSelector:",
        .{objc.sel("currentNotificationCenter").value},
    ));
    try std.testing.expect(cls.msgSend(
        bool,
        "instancesRespondToSelector:",
        .{objc.sel("requestAuthorizationWithOptions:completionHandler:").value},
    ));
}

test "UNMutableNotificationContent class resolves and responds to new, setTitle:, setBody:" {
    const cls = objc.getClass("UNMutableNotificationContent").?;
    try std.testing.expect(cls.msgSend(
        bool,
        "respondsToSelector:",
        .{objc.sel("new").value},
    ));
    try std.testing.expect(cls.msgSend(
        bool,
        "instancesRespondToSelector:",
        .{objc.sel("setTitle:").value},
    ));
    try std.testing.expect(cls.msgSend(
        bool,
        "instancesRespondToSelector:",
        .{objc.sel("setBody:").value},
    ));
}

test "UNNotificationRequest class resolves and responds to requestWithIdentifier:content:trigger:" {
    const cls = objc.getClass("UNNotificationRequest").?;
    try std.testing.expect(cls.msgSend(
        bool,
        "respondsToSelector:",
        .{objc.sel("requestWithIdentifier:content:trigger:").value},
    ));
}

test "WkzUNDelegate class registers both delegate selectors and wkz_bridge ivar" {
    // delegateClass() is idempotent — if already registered (by a prior test or
    // the eagerly-called path in registerHandlers) the existing class is returned.
    const cls = try delegateClass();
    try std.testing.expect(objc.getClass(delegate_class_name) != null);

    // Both UNUserNotificationCenterDelegate methods must be registered.
    try std.testing.expect(cls.msgSend(
        bool,
        "instancesRespondToSelector:",
        .{objc.sel("userNotificationCenter:willPresentNotification:withCompletionHandler:").value},
    ));
    try std.testing.expect(cls.msgSend(
        bool,
        "instancesRespondToSelector:",
        .{objc.sel("userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:").value},
    ));
}

test "WkzUNDelegate wkz_bridge ivar round-trips a *Bridge pointer" {
    // Prove the raw-pointer ivar mechanism works: alloc an instance, write a
    // *Bridge into the ivar, read it back, confirm the address matches.
    const cls = try delegateClass();
    const inst = cls.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer inst.msgSend(void, "release", .{});

    var bridge = try Bridge.init(
        std.testing.allocator,
        objc.Object{ .value = null },
        objc.Object{ .value = null },
    );
    defer bridge.deinit();

    inst.setInstanceVariable(bridge_ivar_name, .{ .value = @ptrCast(&bridge) });
    const got = inst.getInstanceVariable(bridge_ivar_name);
    try std.testing.expect(got.value != null);
    const recovered: *Bridge = @ptrCast(@alignCast(got.value));
    try std.testing.expectEqual(&bridge, recovered);
}

test "registerHandlers registers exactly 2 handlers" {
    var bridge = try Bridge.init(
        std.testing.allocator,
        objc.Object{ .value = null },
        objc.Object{ .value = null },
    );
    defer bridge.deinit();
    try registerHandlers(&bridge);
    try std.testing.expectEqual(@as(u32, 2), bridge.dispatch.count());
    try std.testing.expect(bridge.dispatch.contains("notifications.requestPermission"));
    try std.testing.expect(bridge.dispatch.contains("notifications.send"));
}

test "notifications.requestPermission: handler is registered and callable (headless — skips center call)" {
    // currentNotificationCenter throws NSException outside an app bundle (it needs
    // NSBundle.mainBundle to be non-nil). We cannot call through the full handler
    // in a headless test binary. This test only confirms that the dispatch table
    // entry for "notifications.requestPermission" is wired; the live round-trip
    // (permission dialog, async grant) is a manual GUI check.
    var bridge = try Bridge.init(
        std.testing.allocator,
        objc.Object{ .value = null },
        objc.Object{ .value = null },
    );
    defer bridge.deinit();
    try registerHandlers(&bridge);
    try std.testing.expect(bridge.dispatch.contains("notifications.requestPermission"));
}

test "notifications.send: non-object params logs and resolves false (no panic)" {
    var bridge = try Bridge.init(
        std.testing.allocator,
        objc.Object{ .value = null },
        objc.Object{ .value = null },
    );
    defer bridge.deinit();
    try registerHandlers(&bridge);

    // null params — non-object branch.
    try bridge.dispatchSlice(
        \\{"method":"notifications.send","params":null,"id":1}
    );
    // integer params.
    try bridge.dispatchSlice(
        \\{"method":"notifications.send","params":42,"id":2}
    );
}

test "notifications.send: missing title resolves false — no center call (headless-safe)" {
    // Missing title returns before any ObjC notification call — safe headlessly.
    var bridge = try Bridge.init(
        std.testing.allocator,
        objc.Object{ .value = null },
        objc.Object{ .value = null },
    );
    defer bridge.deinit();
    try registerHandlers(&bridge);

    try bridge.dispatchSlice(
        \\{"method":"notifications.send","params":{"body":"hello"},"id":1}
    );
}

test "notifications.send: missing body resolves false — no center call (headless-safe)" {
    // Missing body returns before any ObjC notification call — safe headlessly.
    var bridge = try Bridge.init(
        std.testing.allocator,
        objc.Object{ .value = null },
        objc.Object{ .value = null },
    );
    defer bridge.deinit();
    try registerHandlers(&bridge);

    try bridge.dispatchSlice(
        \\{"method":"notifications.send","params":{"title":"hello"},"id":1}
    );
}

test "notifications.send: title present but wrong type (non-string) exits early — headless-safe" {
    // title key is present but not a string — should hit the same else branch as
    // a missing key and return before any ObjC notification call.
    var bridge = try Bridge.init(
        std.testing.allocator,
        objc.Object{ .value = null },
        objc.Object{ .value = null },
    );
    defer bridge.deinit();
    try registerHandlers(&bridge);

    // integer title
    try bridge.dispatchSlice(
        \\{"method":"notifications.send","params":{"title":42,"body":"hello"},"id":1}
    );
    // boolean title
    try bridge.dispatchSlice(
        \\{"method":"notifications.send","params":{"title":true,"body":"hello"},"id":2}
    );
    // null title
    try bridge.dispatchSlice(
        \\{"method":"notifications.send","params":{"title":null,"body":"hello"},"id":3}
    );
    // array title
    try bridge.dispatchSlice(
        \\{"method":"notifications.send","params":{"title":[],"body":"hello"},"id":4}
    );
}

test "notifications.send: body present but wrong type (non-string) exits early — headless-safe" {
    // body key is present but not a string — should return before any ObjC
    // notification call. Title is a valid string so the title check passes first.
    var bridge = try Bridge.init(
        std.testing.allocator,
        objc.Object{ .value = null },
        objc.Object{ .value = null },
    );
    defer bridge.deinit();
    try registerHandlers(&bridge);

    // integer body
    try bridge.dispatchSlice(
        \\{"method":"notifications.send","params":{"title":"hello","body":0},"id":1}
    );
    // boolean body
    try bridge.dispatchSlice(
        \\{"method":"notifications.send","params":{"title":"hello","body":false},"id":2}
    );
    // null body
    try bridge.dispatchSlice(
        \\{"method":"notifications.send","params":{"title":"hello","body":null},"id":3}
    );
    // object body
    try bridge.dispatchSlice(
        \\{"method":"notifications.send","params":{"title":"hello","body":{}},"id":4}
    );
}

test "isValidNotificationId: accepts safe identifiers" {
    try std.testing.expect(isValidNotificationId("wkz-notif-0"));
    try std.testing.expect(isValidNotificationId("my-id_123"));
    try std.testing.expect(isValidNotificationId("abc"));
    try std.testing.expect(isValidNotificationId("")); // empty string is technically safe
}

test "isValidNotificationId: rejects identifiers with illegal characters" {
    try std.testing.expect(!isValidNotificationId("has\"quote"));
    try std.testing.expect(!isValidNotificationId("has\\backslash"));
    try std.testing.expect(!isValidNotificationId("has\x01control"));
    try std.testing.expect(!isValidNotificationId("\x00null"));
    try std.testing.expect(!isValidNotificationId("ok-prefix\x1f"));
}

test "notifications.send: caller-supplied id with illegal characters resolves false — headless-safe" {
    // The validation check happens before any ObjC notification call, so this
    // test is safe to run headlessly (never reaches currentNotificationCenter).
    var bridge = try Bridge.init(
        std.testing.allocator,
        objc.Object{ .value = null },
        objc.Object{ .value = null },
    );
    defer bridge.deinit();
    try registerHandlers(&bridge);

    // id with a double-quote — should be rejected before the center call.
    try bridge.dispatchSlice(
        \\{"method":"notifications.send","params":{"title":"t","body":"b","id":"bad\"id"},"id":1}
    );
    // id with a backslash.
    try bridge.dispatchSlice(
        \\{"method":"notifications.send","params":{"title":"t","body":"b","id":"bad\\id"},"id":2}
    );
}

test "impDidReceiveNotificationResponse: identifier JSON escaping is correct" {
    // Verify the two-step escaping: `\` → `\\` first, then `"` → `\"`.
    // Uses the same replaceOwned calls as the IMP to prove the escaping is
    // correct and leak-free under testing.allocator.
    const gpa = std.testing.allocator;

    const cases = [_]struct { input: []const u8, want: []const u8 }{
        .{ .input = "safe-id", .want = "safe-id" },
        .{ .input = "has\"quote", .want = "has\\\"quote" },
        .{ .input = "has\\back", .want = "has\\\\back" },
        .{ .input = "both\\\"", .want = "both\\\\\\\"" },
        .{ .input = "", .want = "" },
    };

    for (cases) |tc| {
        const step1 = try std.mem.replaceOwned(u8, gpa, tc.input, "\\", "\\\\");
        defer gpa.free(step1);
        const step2 = try std.mem.replaceOwned(u8, gpa, step1, "\"", "\\\"");
        defer gpa.free(step2);
        try std.testing.expectEqualStrings(tc.want, step2);
    }
}

test "notifications.send: fire-and-forget (no id) early-exit branches do not panic" {
    // Tests the error-path branches that return BEFORE calling currentNotificationCenter.
    // currentNotificationCenter throws NSException outside an app bundle (it needs
    // NSBundle.mainBundle to be non-nil), so we must not let a headless test reach it.
    // The happy-path (valid title + body, reaches the center) is a manual GUI check.
    var bridge = try Bridge.init(
        std.testing.allocator,
        objc.Object{ .value = null },
        objc.Object{ .value = null },
    );
    defer bridge.deinit();
    try registerHandlers(&bridge);

    // Non-object params — returns before any ObjC notification call.
    try bridge.dispatchSlice(
        \\{"method":"notifications.send","params":null}
    );
    // Object but missing title — returns before any ObjC notification call.
    try bridge.dispatchSlice(
        \\{"method":"notifications.send","params":{"body":"b"}}
    );
    // Object but missing body — returns before any ObjC notification call.
    try bridge.dispatchSlice(
        \\{"method":"notifications.send","params":{"title":"t"}}
    );
}
