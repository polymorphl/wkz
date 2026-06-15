//! Window focus/blur events via NSNotificationCenter.
//!
//! Responsibility: register a custom `WkzWindowObserver` NSObject subclass
//! that subscribes to `NSWindowDidBecomeKeyNotification` and
//! `NSWindowDidResignKeyNotification` on a specific NSWindow. When either
//! fires, the IMP pushes a typed event to the JS side via `bridge.evaluate`.
//!
//! **Design**: an ObjC observer object is registered with
//! `NSNotificationCenter.defaultCenter` for the two key-focus notifications.
//! The observer's `handleNotification:` IMP recovers a heap-allocated
//! `*WindowEvents` from its `wkz_obs_ctx` ivar and calls `bridge.evaluate`
//! with a sentinel-terminated JS string.
//!
//! **ARC**:
//!   - `observer` is `+1` from `alloc/init`, owned by `WindowEvents`, released
//!     by `deinit`.
//!   - `NSNotificationCenter.defaultCenter` is a singleton — never released.
//!   - NSStrings produced by `stringWithUTF8String:` are autoreleased — never
//!     released by us.
//!   - The heap-allocated `*WindowEvents` (context for the IMP) is freed in
//!     `deinit`, AFTER `removeObserver:` and BEFORE `release`, so the IMP
//!     cannot fire with a dangling pointer after deregistration.
//!
//! **No ObjC blocks.** Events are delivered through `bridge.evaluate`.
//! **Main thread only.** All AppKit and NSNotificationCenter calls happen on
//! the main thread.

const std = @import("std");
const objc = @import("objc");
const c = objc.c;
const Bridge = @import("bridge.zig").Bridge;
const Window = @import("window.zig").Window;

const log = std.log.scoped(.wkz_events);

/// Process-unique name for the `WkzWindowObserver` NSObject subclass.
const class_name: [:0]const u8 = "WkzWindowObserver";

/// Name of the `id`-typed instance variable storing a borrowed `*WindowEvents`.
const ivar_name: [:0]const u8 = "wkz_obs_ctx";

/// Errors surfaced while initialising the window observer.
pub const Error = error{
    /// A required AppKit class could not be looked up.
    ClassNotFound,
    /// `objc_allocateClassPair` returned nil. Should be unreachable after the
    /// idempotency guard.
    ClassRegistrationFailed,
} || std.mem.Allocator.Error;

/// Window focus/blur event observer attached to one window.
///
/// Ownership:
///   - `observer` is a `+1` instance of `WkzWindowObserver` (alloc/init),
///     owned by this struct and released by `deinit`.
///   - `bridge` is BORROWED (not +1). The caller keeps it alive.
///   - The context pointer written into the ivar is a raw borrow — no retain.
pub const WindowEvents = struct {
    allocator: std.mem.Allocator,
    bridge: *Bridge,
    /// Owned `+1` observer NSObject. Released by `deinit`.
    observer: objc.Object,

    /// Create and attach a window-focus/blur observer to `window`.
    ///
    /// Registers the `WkzWindowObserver` class once per process (idempotent).
    /// On the error path nothing is leaked: `errdefer observer.release` balances
    /// the `alloc/init` on every fallible step.
    ///
    /// `bridge` is borrowed — the caller must keep it alive for the lifetime of
    /// this `WindowEvents`. Must be called on the main thread.
    pub fn init(
        allocator: std.mem.Allocator,
        window: Window,
        bridge: *Bridge,
    ) Error!WindowEvents {
        // Register the class once per process — idempotent.
        if (objc.getClass(class_name) == null) {
            const NSObject = objc.getClass("NSObject") orelse return Error.ClassNotFound;
            const cls = objc.allocateClassPair(NSObject, class_name) orelse
                return Error.ClassRegistrationFailed;
            std.debug.assert(cls.addIvar(ivar_name));
            std.debug.assert(cls.addMethod("handleNotification:", impHandleNotification));
            objc.registerClassPair(cls);
        }

        const WkzWindowObserver = objc.getClass(class_name) orelse
            return Error.ClassNotFound;

        // alloc/init -> +1 owned by this struct (released in deinit).
        const observer = WkzWindowObserver.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "init", .{});
        errdefer observer.msgSend(void, "release", .{});

        // Allocate WindowEvents on the heap so the IMP can recover it from the
        // ivar. The pointer must remain stable for the observer's lifetime.
        const self_ptr = try allocator.create(WindowEvents);
        errdefer allocator.destroy(self_ptr);

        // Write the heap pointer into the ivar (raw store, no retain).
        // setInstanceVariable takes (name: [:0]const u8, val: objc.Object).
        // zig-objc object.zig:115 — verified against pinned tarball.
        observer.setInstanceVariable(ivar_name, .{ .value = @ptrCast(self_ptr) });

        // Register for the two key-focus notifications on the specific window.
        const NSNotificationCenter = objc.getClass("NSNotificationCenter") orelse
            return Error.ClassNotFound;
        const NSString = objc.getClass("NSString") orelse return Error.ClassNotFound;

        const nc = NSNotificationCenter.msgSend(objc.Object, "defaultCenter", .{});

        // stringWithUTF8String: returns an autoreleased NSString — no +1, no release.
        const become_key = NSString.msgSend(
            objc.Object,
            "stringWithUTF8String:",
            .{"NSWindowDidBecomeKeyNotification"},
        );
        const resign_key = NSString.msgSend(
            objc.Object,
            "stringWithUTF8String:",
            .{"NSWindowDidResignKeyNotification"},
        );
        const sel_handle = objc.sel("handleNotification:");

        // addObserver:selector:name:object: — `object` is the specific window
        // so we only receive notifications from that one window.
        nc.msgSend(void, "addObserver:selector:name:object:", .{
            observer,
            sel_handle.value,
            become_key,
            window.ns_window,
        });
        nc.msgSend(void, "addObserver:selector:name:object:", .{
            observer,
            sel_handle.value,
            resign_key,
            window.ns_window,
        });

        // The heap allocation persists as the IMP's context (via ivar). The
        // caller receives a by-value copy that carries the same observer handle
        // and bridge pointer. deinit() recovers and destroys the heap allocation
        // via the ivar before releasing the observer — avoiding the
        // stable-address problem of returning a pointer to a local while still
        // working as a value type for the caller.
        self_ptr.* = .{
            .allocator = allocator,
            .bridge = bridge,
            .observer = observer,
        };
        // Return a by-value copy; the IMP continues to use the heap allocation
        // via the ivar, so the caller's copy is safe to move or store anywhere.
        return self_ptr.*;
    }

    /// Deregister all observations, release the owned `+1` observer reference,
    /// and free the heap-allocated context. Must be called on the main thread.
    ///
    /// Order is critical to avoid use-after-free:
    ///   1. `removeObserver:` — prevents any future `handleNotification:` call.
    ///   2. Recover the heap pointer from the ivar.
    ///   3. `release` the observer (drops our +1).
    ///   4. `destroy` the heap allocation.
    pub fn deinit(self: WindowEvents) void {
        // 1. Deregister all observations so the IMP cannot fire after this point.
        const NSNotificationCenter = objc.getClass("NSNotificationCenter") orelse return;
        const nc = NSNotificationCenter.msgSend(objc.Object, "defaultCenter", .{});
        nc.msgSend(void, "removeObserver:", .{self.observer});

        // 2. Recover the heap context BEFORE releasing the observer object so we
        //    can safely free it after the ObjC object is gone.
        const ctx_obj = self.observer.getInstanceVariable(ivar_name);
        const heap_ctx: ?*WindowEvents = if (ctx_obj.value != null)
            @ptrCast(@alignCast(ctx_obj.value.?))
        else
            null;

        // 3. Release the observer (+1 → 0).
        self.observer.msgSend(void, "release", .{});

        // 4. Free the heap allocation.
        if (heap_ctx) |ctx| self.allocator.destroy(ctx);
    }
};

// =====================================================================
// ObjC IMP
// =====================================================================

/// `-[WkzWindowObserver handleNotification:]`
///
/// Called by NSNotificationCenter on the main thread when the observed window
/// becomes or resigns key. Recovers `*WindowEvents` from the ivar, maps the
/// notification name to an event type string, builds a JS call, and evaluates
/// it via the bridge.
///
/// ARC: all ObjC objects here are borrowed from the notification — no
/// retain/release needed. The JS string is allocated and freed within this
/// function.
fn impHandleNotification(
    self_id: c.id,
    _: c.SEL,
    notif_id: c.id,
) callconv(.c) void {
    const self_obj = objc.Object{ .value = self_id };
    const ctx_obj = self_obj.getInstanceVariable(ivar_name);
    if (ctx_obj.value == null) return;
    const ctx: *WindowEvents = @ptrCast(@alignCast(ctx_obj.value.?));

    const notif = objc.Object{ .value = notif_id };
    // -[NSNotification name] returns an autoreleased NSString.
    const name_obj = notif.msgSend(objc.Object, "name", .{});
    // -UTF8String returns a borrowed C string — do not free.
    const name_cstr = name_obj.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse return;
    const name = std.mem.span(name_cstr);

    const event_type: [:0]const u8 = if (std.mem.eql(u8, name, "NSWindowDidBecomeKeyNotification"))
        "window.focused"
    else if (std.mem.eql(u8, name, "NSWindowDidResignKeyNotification"))
        "window.blurred"
    else
        return;

    // Build the JS call as a sentinel-terminated string.
    // std.fmt.allocPrintSentinel (fmt.zig:639):
    //   pub fn allocPrintSentinel(gpa, comptime fmt, args, comptime sentinel) ![:sentinel]u8
    const js = std.fmt.allocPrintSentinel(
        ctx.allocator,
        "__wkz_event({{\"type\":\"{s}\"}})",
        .{event_type},
        0,
    ) catch {
        log.warn("events: OOM building event JS for {s}", .{event_type});
        return;
    };
    defer ctx.allocator.free(js);
    ctx.bridge.evaluate(js);
}

// =====================================================================
// Tests
// =====================================================================

test "NSNotificationCenter class resolves in ObjC runtime" {
    try std.testing.expect(objc.getClass("NSNotificationCenter") != null);
}

test "NSNotificationCenter instances respond to required selectors" {
    const NSNotificationCenter = objc.getClass("NSNotificationCenter").?;
    const selectors = [_][:0]const u8{
        "defaultCenter",
        "addObserver:selector:name:object:",
        "removeObserver:",
    };
    // defaultCenter is a class method — test it separately.
    const responds_dc = NSNotificationCenter.msgSend(
        bool,
        "respondsToSelector:",
        .{objc.sel("defaultCenter").value},
    );
    try std.testing.expect(responds_dc);

    // The remaining selectors are instance methods.
    for (selectors[1..]) |sel| {
        const responds = NSNotificationCenter.msgSend(
            bool,
            "instancesRespondToSelector:",
            .{objc.sel(sel).value},
        );
        try std.testing.expect(responds);
    }
}

test "WkzWindowObserver class registration is idempotent" {
    // First registration (or no-op if already registered by a prior test run).
    if (objc.getClass(class_name) == null) {
        const NSObject = objc.getClass("NSObject").?;
        const cls = objc.allocateClassPair(NSObject, class_name).?;
        std.debug.assert(cls.addIvar(ivar_name));
        std.debug.assert(cls.addMethod("handleNotification:", impHandleNotification));
        objc.registerClassPair(cls);
    }
    const a = objc.getClass(class_name);
    try std.testing.expect(a != null);

    // Second call (idempotency guard path) — must not panic or return an error.
    if (objc.getClass(class_name) == null) {
        const NSObject = objc.getClass("NSObject").?;
        const cls = objc.allocateClassPair(NSObject, class_name).?;
        std.debug.assert(cls.addIvar(ivar_name));
        std.debug.assert(cls.addMethod("handleNotification:", impHandleNotification));
        objc.registerClassPair(cls);
    }
    const b = objc.getClass(class_name);
    try std.testing.expect(b != null);

    // Both lookups return the same class object.
    try std.testing.expectEqual(a.?.value, b.?.value);
}

test "WkzWindowObserver instances respond to handleNotification:" {
    // Ensure class is registered.
    if (objc.getClass(class_name) == null) {
        const NSObject = objc.getClass("NSObject").?;
        const cls = objc.allocateClassPair(NSObject, class_name).?;
        std.debug.assert(cls.addIvar(ivar_name));
        std.debug.assert(cls.addMethod("handleNotification:", impHandleNotification));
        objc.registerClassPair(cls);
    }
    const cls = objc.getClass(class_name).?;
    const responds = cls.msgSend(
        bool,
        "instancesRespondToSelector:",
        .{objc.sel("handleNotification:").value},
    );
    try std.testing.expect(responds);
}

test "WkzWindowObserver IMP nil-ivar guard does not crash" {
    // Ensure the class is registered so we can alloc an instance.
    if (objc.getClass(class_name) == null) {
        const NSObject = objc.getClass("NSObject").?;
        const cls = objc.allocateClassPair(NSObject, class_name).?;
        std.debug.assert(cls.addIvar(ivar_name));
        std.debug.assert(cls.addMethod("handleNotification:", impHandleNotification));
        objc.registerClassPair(cls);
    }
    const cls = objc.getClass(class_name).?;
    const obs = cls.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer obs.msgSend(void, "release", .{});

    // The ivar is zero-initialised (nil) — do NOT set it.
    // Call the IMP directly as a plain Zig function so we control both
    // arguments precisely. `self_id = obs.value` (ivar == nil) must trigger
    // the nil-ctx early return before any dereference.  `notif_id = null`
    // is safe because the ivar check (line 199) runs before the notification
    // object is touched.
    impHandleNotification(obs.value, null, null);
    // Reaching here without a panic proves the nil-ctx guard fired correctly.
}

test {
    std.testing.refAllDecls(@This());
}
