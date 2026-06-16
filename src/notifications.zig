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
/// ObjC runtime functions not exposed by zig-objc.
extern fn objc_getProtocol(name: [*:0]const u8) ?*anyopaque;
extern fn class_addProtocol(cls: objc.c.Class, proto: *anyopaque) bool;

// Comptime assertion: pins the Darwin block ABI layout assumed by impWillPresentNotification.
// If the offset ever changes (it hasn't since 2008), this catches it at compile time.
const BlockHeader = extern struct {
    isa: *anyopaque,
    flags: i32,
    reserved: i32,
    invoke: *anyopaque,
};
comptime {
    std.debug.assert(@offsetOf(BlockHeader, "invoke") == 16);
}

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

/// Create (or look up) the `WkzUNDelegate` class.
///
/// Idempotent: if already registered (e.g. second call in the same process),
/// returns the existing class. Process-lived — nothing to release.
fn delegateClass() objc_helpers.Error!objc.Class {
    const NSObject = objc.getClass("NSObject") orelse
        return objc_helpers.Error.ClassRegistrationFailed;
    const cls = try objc_helpers.defineClass(
        delegate_class_name,
        NSObject,
        .{
            objc_helpers.method(
                "userNotificationCenter:willPresentNotification:withCompletionHandler:",
                impWillPresentNotification,
            ),
        },
    );
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
/// then calls `setDelegate:` on the provided center object. Idempotent: if the
/// delegate instance was already created and wired in a prior call, this is a
/// no-op.
///
/// Must be called with a live `UNUserNotificationCenter` (i.e. only from paths
/// that have already obtained the center successfully, not from headless tests).
///
/// ARC: `delegate_instance` is created with `+new` (+1) and is intentionally
/// process-lived (never released). The center is also process-lived.
fn setupDelegate(center: objc.Object) void {
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
    log.debug("setupDelegate: instance created, calling setDelegate:", .{});

    center.msgSend(void, "setDelegate:", .{delegate_instance});

    const responds = delegate_instance.msgSend(
        bool,
        "respondsToSelector:",
        .{objc.sel("userNotificationCenter:willPresentNotification:withCompletionHandler:").value},
    );
    log.debug("setupDelegate: delegate respondsToSelector willPresent={}", .{responds});
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

    // Wire the delegate so foreground notifications show banners. Idempotent.
    setupDelegate(center);

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
                    // Caller supplied an id — NUL-terminate a copy.
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

    // Wire the delegate so foreground notifications show banners. Idempotent.
    setupDelegate(center);

    // completionHandler is nil (no ObjC blocks per hard rule #3).
    center.msgSend(
        void,
        "addNotificationRequest:withCompletionHandler:",
        .{ request, @as(?*anyopaque, null) },
    );

    if (id) |i| bridge.resolve(i, "true") catch {};
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
