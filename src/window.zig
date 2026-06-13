//! NSWindow creation and configuration.
//!
//! Responsibility: build an NSWindow (titled, closable, resizable), center it
//! on screen, set its title, and bring it to front via makeKeyAndOrderFront.
//! The window's contentView is later filled by the WKWebView (M1.4). Main
//! thread only.

const std = @import("std");
const objc = @import("objc");
const c = objc.c;

/// `NSWindowStyleMask` flag values (AppKit/NSWindow.h). Stable since 10.0.
/// Combined into the style mask passed to `initWithContentRect:...`.
const NSWindowStyleMaskTitled: c_ulong = 1 << 0;
const NSWindowStyleMaskClosable: c_ulong = 1 << 1;
const NSWindowStyleMaskResizable: c_ulong = 1 << 3;

/// `NSBackingStoreType` value (AppKit/NSGraphics.h). `Buffered` is the only
/// backing store store supported on modern macOS.
const NSBackingStoreBuffered: c_ulong = 2;

/// `CGFloat` on 64-bit Apple platforms is a `double`. NSWindow geometry is
/// expressed in these. Public so sibling modules (e.g. webview.zig) share the
/// one canonical Core Graphics geometry ABI rather than redefining it.
pub const CGFloat = f64;

/// `CGPoint` / `NSPoint`: the origin of a rect, in points.
/// `extern struct` so it is passed by value over the C ABI by zig-objc's
/// msgSend (which requires extern/packed layout for struct arguments).
pub const CGPoint = extern struct {
    x: CGFloat,
    y: CGFloat,
};

/// `CGSize` / `NSSize`: the extent of a rect, in points.
pub const CGSize = extern struct {
    width: CGFloat,
    height: CGFloat,
};

/// `CGRect` / `NSRect`: the content rectangle handed to NSWindow. 32 bytes
/// (4 × f64); zig-objc selects the correct objc_msgSend variant for the size
/// and architecture automatically.
pub const CGRect = extern struct {
    origin: CGPoint,
    size: CGSize,
};

/// Errors surfaced while creating a window.
pub const Error = error{
    /// A required AppKit class could not be looked up in the runtime. This
    /// only happens if AppKit failed to link/load, which is fatal.
    ClassNotFound,
};

/// Process-unique names for the WkzWindowDelegate ObjC class and its ivars.
const win_delegate_class_name: [:0]const u8 = "WkzWindowDelegate";
const win_ctx_ivar_name: [:0]const u8 = "wkz_win_ctx";
const win_fn_ivar_name: [:0]const u8 = "wkz_win_fn";

/// Pairs a user context pointer with its close callback. Stored inline in
/// `Window` (no heap allocation) so `wkz_win_ctx` can hold `*CloseBundle`
/// without a separate allocation. The `Window` struct must not move after
/// `setCloseHandler` is called (the delegate holds a pointer into it).
const CloseBundle = struct {
    ctx: *anyopaque,
    callback: *const fn (*anyopaque) void,
};

/// Dispatcher stored in `wkz_win_fn`. Declared `align(8)` so its address is
/// always a multiple of 8 and can be safely stored in an `id`-typed ivar via
/// `@ptrFromInt` without triggering Zig's Debug-mode alignment safety check.
/// `wkz_win_ctx` holds a `*CloseBundle`; this fn dereferences it and invokes
/// the user callback.
fn dispatchClose(opaque_bundle: *anyopaque) align(8) void {
    const bundle: *CloseBundle = @ptrCast(@alignCast(opaque_bundle));
    bundle.callback(bundle.ctx);
}

/// Create (or look up) the WkzWindowDelegate class. Idempotent.
fn winDelegateClass() Error!objc.Class {
    if (objc.getClass(win_delegate_class_name)) |existing| return existing;
    const NSObject = objc.getClass("NSObject") orelse return Error.ClassNotFound;
    const cls = objc.allocateClassPair(NSObject, win_delegate_class_name) orelse
        return Error.ClassNotFound;
    errdefer objc.disposeClassPair(cls);
    // Both ivars are id-typed (pointer-width). Must be added before registerClassPair.
    std.debug.assert(cls.addIvar(win_ctx_ivar_name));
    std.debug.assert(cls.addIvar(win_fn_ivar_name));
    std.debug.assert(cls.addMethod("windowWillClose:", impWindowWillClose));
    objc.registerClassPair(cls);
    return cls;
}

/// IMP for -[WkzWindowDelegate windowWillClose:].
/// Reads `*CloseBundle` from `wkz_win_ctx` and the `dispatchClose` fn from
/// `wkz_win_fn`, then calls `dispatchClose(bundle)` which in turn invokes the
/// user callback. Fires before NSWindow deallocates — all pointers are valid.
fn impWindowWillClose(
    self: c.id,
    _cmd: c.SEL,
    notification: c.id,
) callconv(.c) void {
    _ = _cmd;
    _ = notification;
    const delegate = objc.Object{ .value = self };
    const ctx_obj = delegate.getInstanceVariable(win_ctx_ivar_name);
    const fn_obj = delegate.getInstanceVariable(win_fn_ivar_name);
    if (ctx_obj.value == null or fn_obj.value == null) return;
    const bundle: *anyopaque = @ptrCast(@alignCast(ctx_obj.value));
    const fn_ptr: *const fn (*anyopaque) void = @ptrCast(@alignCast(fn_obj.value));
    fn_ptr(bundle);
}

/// A titled/closable/resizable NSWindow, centered and shown.
///
/// Ownership: `init` produces a `+1` NSWindow reference (alloc/init) that this
/// struct owns. `deinit` releases it. The window must outlive any view added to
/// it (the WKWebView in M1.4), so callers keep the `Window` alive for as long
/// as the window is on screen — typically for the whole app lifetime, dropped
/// only at shutdown. No ARC: the single owning reference is balanced by the one
/// `release` in `deinit`.
pub const Window = struct {
    /// The owned `NSWindow` (`+1`). Released by `deinit`.
    ns_window: objc.Object,
    /// The owned `WkzWindowDelegate` (`+1`), if set. Released by `deinit`.
    delegate: ?objc.Object = null,
    /// Inline storage for the close bundle (ctx + callback). `setCloseHandler`
    /// stores `&self.close_bundle.?` in the delegate's `wkz_win_ctx` ivar, so
    /// the `Window` must not move after `setCloseHandler` is called.
    close_bundle: ?CloseBundle = null,

    /// Create a titled/closable/resizable NSWindow of `width`×`height` points,
    /// center it on screen, apply `title`, and order it to the front.
    ///
    /// Must be called on the main thread. On success the returned `Window` owns
    /// a `+1` NSWindow reference that `deinit` releases. On the error path no
    /// reference is leaked: `errdefer release` balances the alloc/init before
    /// the title NSString is built.
    pub fn init(width: CGFloat, height: CGFloat, title: [:0]const u8) Error!Window {
        const NSWindow = objc.getClass("NSWindow") orelse return Error.ClassNotFound;
        const NSString = objc.getClass("NSString") orelse return Error.ClassNotFound;

        const content_rect: CGRect = .{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = width, .height = height },
        };
        const style_mask: c_ulong =
            NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable;

        // alloc/init -> +1 reference owned by this struct (released in deinit).
        const ns_window = NSWindow.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithContentRect:styleMask:backing:defer:", .{
            content_rect,
            style_mask,
            NSBackingStoreBuffered,
            @as(bool, false),
        });
        errdefer ns_window.msgSend(void, "release", .{});

        // Title: a +1 NSString that NSWindow copies; we release our reference.
        const ns_title = nsString(NSString, title);
        defer ns_title.msgSend(void, "release", .{});
        ns_window.msgSend(void, "setTitle:", .{ns_title});

        // Center on screen, then show and make key.
        ns_window.msgSend(void, "center", .{});
        ns_window.msgSend(void, "makeKeyAndOrderFront:", .{@as(?*anyopaque, null)});

        return .{ .ns_window = ns_window };
    }

    /// The window's `contentView` (an `NSView`) — the surface a WKWebView is
    /// added to (M1.4). The returned reference is owned by the NSWindow, not the
    /// caller: do NOT release it. Must be called on the main thread.
    pub fn contentView(self: Window) objc.Object {
        return self.ns_window.msgSend(objc.Object, "contentView", .{});
    }

    /// Release the owned NSWindow reference. After this the `Window` is dead.
    /// Also releases the delegate if one was set via `setCloseHandler`.
    /// Must be called on the main thread.
    pub fn deinit(self: Window) void {
        // Release ns_window first: this clears NSWindow's weak delegate pointer,
        // so no further delegate calls can fire after the delegate is released.
        self.ns_window.msgSend(void, "release", .{});
        if (self.delegate) |d| d.msgSend(void, "release", .{});
    }

    /// Register a callback fired when this window is about to close.
    ///
    /// Creates a `WkzWindowDelegate` instance, stores `ctx` and `callback` in its
    /// ivars, and sets it as the window's delegate. Replaces any prior delegate
    /// (releases the old one first). The delegate fires `callback(ctx)` from its
    /// `windowWillClose:` IMP, before NSWindow deallocates.
    ///
    /// `ctx` is NOT owned by the delegate — the caller remains responsible for
    /// `ctx` lifetime. `callback` must remain valid for as long as the window is
    /// open. Must be called on the main thread.
    ///
    /// After this call the `Window` must not be moved in memory (no copy-by-value,
    /// no `ArrayList` realloc): the delegate holds a pointer into `self.close_bundle`.
    pub fn setCloseHandler(
        self: *Window,
        ctx: *anyopaque,
        callback: *const fn (*anyopaque) void,
    ) Error!void {
        const cls = try winDelegateClass();
        if (self.delegate) |old| {
            old.msgSend(void, "release", .{});
            self.delegate = null;
        }
        const delegate = cls.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "init", .{});
        // Store ctx + callback in the inline CloseBundle, then point the
        // delegate's wkz_win_ctx ivar at it. The bundle lives in *self, so
        // Window must not move after this call.
        self.close_bundle = .{ .ctx = ctx, .callback = callback };
        delegate.setInstanceVariable(win_ctx_ivar_name, .{ .value = @ptrCast(&self.close_bundle.?) });
        // dispatchClose is declared align(8), guaranteeing its address is a
        // multiple of 8 — safe to store in an id-typed ivar via @ptrFromInt.
        delegate.setInstanceVariable(win_fn_ivar_name, .{ .value = @ptrFromInt(@intFromPtr(&dispatchClose)) });
        self.delegate = delegate;
        self.ns_window.msgSend(void, "setDelegate:", .{delegate});
    }

    /// Replace the window's title. `title` is copied by NSWindow; the transient
    /// NSString built here is released. Must be called on the main thread.
    pub fn setTitle(self: Window, title: [:0]const u8) Error!void {
        const NSString = objc.getClass("NSString") orelse return Error.ClassNotFound;
        const ns_title = nsString(NSString, title);
        defer ns_title.msgSend(void, "release", .{});
        self.ns_window.msgSend(void, "setTitle:", .{ns_title});
    }

    /// Move the window's bottom-left corner to `(x, y)` in screen coordinates
    /// (AppKit origin: bottom-left of primary screen). Does not resize.
    /// Must be called on the main thread.
    pub fn setPosition(self: Window, x: CGFloat, y: CGFloat) void {
        self.ns_window.msgSend(void, "setFrameOrigin:", .{CGPoint{ .x = x, .y = y }});
    }

    /// Position this window in cascade from `point` (top-left, screen coords)
    /// and return the suggested top-left origin for the next window. Pass the
    /// returned value to the next window's `cascadeFrom` call for the standard
    /// macOS cascade layout. Must be called on the main thread.
    pub fn cascadeFrom(self: Window, point: CGPoint) CGPoint {
        return self.ns_window.msgSend(CGPoint, "cascadeTopLeftFromPoint:", .{point});
    }
};

/// Returns a `+1` NSString built from a UTF-8 C string. Caller owns it and must
/// `release` it. `-[NSString stringWithUTF8String:]` returns an autoreleased
/// string; since wkz drains no autorelease pool here, we `retain` it to get a
/// deterministic, ARC-free `+1` reference the caller releases explicitly.
fn nsString(NSString: objc.Class, str: [:0]const u8) objc.Object {
    const s = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{str.ptr});
    return s.msgSend(objc.Object, "retain", .{});
}

// --- Compile-time constant / layout contracts (no AppKit calls) ---

test "style mask / backing constants match AppKit" {
    try std.testing.expectEqual(@as(c_ulong, 1), NSWindowStyleMaskTitled);
    try std.testing.expectEqual(@as(c_ulong, 2), NSWindowStyleMaskClosable);
    try std.testing.expectEqual(@as(c_ulong, 8), NSWindowStyleMaskResizable);
    try std.testing.expectEqual(@as(c_ulong, 2), NSBackingStoreBuffered);
}

test "CGRect has the C ABI layout AppKit expects" {
    // NSRect is { NSPoint origin; NSSize size; } of four CGFloat (f64) on
    // 64-bit Apple platforms: 32 bytes, extern layout so it passes by value.
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(CGRect));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(CGRect, "origin"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(CGRect, "size"));
    try std.testing.expectEqual(std.builtin.Type.ContainerLayout.@"extern", @typeInfo(CGRect).@"struct".layout);
}

test "CGPoint / CGSize / CGFloat have the C ABI layout AppKit expects" {
    // CGRect's by-value ABI is only correct if its members have the exact
    // NSPoint/NSSize layout: two CGFloat (f64) each, 16 bytes, extern. A drift
    // in either silently corrupts the content rect passed to NSWindow.
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(CGFloat));
    try std.testing.expectEqual(f64, CGFloat);

    try std.testing.expectEqual(@as(usize, 16), @sizeOf(CGPoint));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(CGPoint, "x"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(CGPoint, "y"));
    try std.testing.expectEqual(std.builtin.Type.ContainerLayout.@"extern", @typeInfo(CGPoint).@"struct".layout);

    try std.testing.expectEqual(@as(usize, 16), @sizeOf(CGSize));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(CGSize, "width"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(CGSize, "height"));
    try std.testing.expectEqual(std.builtin.Type.ContainerLayout.@"extern", @typeInfo(CGSize).@"struct".layout);
}

// --- API-surface / type contract (compile-time) ---

test "Window exposes the documented public API surface" {
    try std.testing.expect(@hasField(Window, "ns_window"));
    try std.testing.expectEqual(objc.Object, @FieldType(Window, "ns_window"));

    const InitRet = @typeInfo(@TypeOf(Window.init)).@"fn".return_type.?;
    try std.testing.expectEqual(Error!Window, InitRet);

    try std.testing.expectEqual(void, @typeInfo(@TypeOf(Window.deinit)).@"fn".return_type.?);

    // contentView() exposes the NSView a WKWebView attaches to (M1.4).
    try std.testing.expectEqual(objc.Object, @typeInfo(@TypeOf(Window.contentView)).@"fn".return_type.?);

    const SetTitleRet = @typeInfo(@TypeOf(Window.setTitle)).@"fn".return_type.?;
    try std.testing.expectEqual(Error!void, SetTitleRet);
}

test "Error set is exactly {ClassNotFound}" {
    const fields = @typeInfo(Error).error_set.?;
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("ClassNotFound", fields[0].name);
}

test "required AppKit classes resolve in the runtime" {
    // Pure runtime lookups — no window-server connection, safe headless.
    try std.testing.expect(objc.getClass("NSWindow") != null);
    try std.testing.expect(objc.getClass("NSString") != null);
}

test "NSWindow instances respond to the selectors init/setTitle use" {
    // Query the loaded AppKit class metadata for the instance methods that
    // init()/setTitle() send. This is a pure runtime lookup against the class
    // object (-[NSWindow instancesRespondToSelector:]) — it allocates no window
    // and opens no window-server connection, so it is headless-safe. A typo in
    // any selector string in init()/setTitle() would otherwise only surface as
    // a silent no-op (or crash) at runtime on a real window.
    const NSWindow = objc.getClass("NSWindow").?;
    const selectors = [_][:0]const u8{
        "initWithContentRect:styleMask:backing:defer:",
        "setTitle:",
        "center",
        "makeKeyAndOrderFront:",
        "contentView",
        "release",
    };
    inline for (selectors) |name| {
        const responds = NSWindow.msgSend(
            bool,
            "instancesRespondToSelector:",
            .{objc.sel(name).value},
        );
        try std.testing.expect(responds);
    }
}

test "NSString instances respond to the selectors nsString uses" {
    // setTitle:/init build a transient NSString via stringWithUTF8String:
    // (a class method) and retain it (an instance method). Verify both resolve
    // against the loaded class metadata. Headless-safe runtime query only.
    const NSString = objc.getClass("NSString").?;
    // +[NSString stringWithUTF8String:] is a class method. Sending
    // respondsToSelector: to the class *object* checks its class methods.
    // (zig-objc's Class.respondsToSelector wraps class_respondsToSelector, which
    // checks *instance* methods, so it is the wrong query here.)
    try std.testing.expect(NSString.msgSend(
        bool,
        "respondsToSelector:",
        .{objc.sel("stringWithUTF8String:").value},
    ));
    // -[NSString retain] is an instance method.
    try std.testing.expect(NSString.msgSend(
        bool,
        "instancesRespondToSelector:",
        .{objc.sel("retain").value},
    ));
}

// NOTE: Window.init() is NOT headless-safe. -[NSWindow initWithContentRect:...]
// and makeKeyAndOrderFront: require a connection to the window server, which is
// absent in headless CI. A live init test would hang or abort there, so window
// creation is deferred to the manual GUI checklist (see TASK.md / M1.x), as
// M1.2 did for run()/activate() GUI behaviour. No live test is added here.

test "Window struct has delegate field of type ?objc.Object" {
    try std.testing.expect(@hasField(Window, "delegate"));
    try std.testing.expectEqual(?objc.Object, @FieldType(Window, "delegate"));
}

test "winDelegateClass registers WkzWindowDelegate with windowWillClose: selector" {
    const cls = try winDelegateClass();
    try std.testing.expect(objc.getClass("WkzWindowDelegate") != null);
    try std.testing.expectEqual(objc.getClass("WkzWindowDelegate").?.value, cls.value);
    try std.testing.expect(cls.msgSend(
        bool,
        "instancesRespondToSelector:",
        .{objc.sel("windowWillClose:").value},
    ));
}

test "winDelegateClass is idempotent" {
    const a = try winDelegateClass();
    const b = try winDelegateClass();
    try std.testing.expectEqual(a.value, b.value);
}

test "WkzWindowDelegate ivars round-trip ctx and fn pointers — dispatch fires" {
    const cls = try winDelegateClass();
    const obj = cls.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer obj.msgSend(void, "release", .{});

    // Sentinel that the callback will set. Proves dispatch fires end-to-end.
    var fired: bool = false;
    const callback: *const fn (*anyopaque) void = &struct {
        fn f(p: *anyopaque) void {
            @as(*bool, @ptrCast(@alignCast(p))).* = true;
        }
    }.f;
    var bundle = CloseBundle{ .ctx = @ptrCast(&fired), .callback = callback };

    // dispatchClose is align(8) — safe to store via @ptrFromInt in an id ivar.
    const fn_ptr = &dispatchClose;
    obj.setInstanceVariable(win_ctx_ivar_name, .{ .value = @ptrCast(&bundle) });
    obj.setInstanceVariable(win_fn_ivar_name, .{ .value = @ptrFromInt(@intFromPtr(fn_ptr)) });

    const got_ctx = obj.getInstanceVariable(win_ctx_ivar_name);
    const got_fn = obj.getInstanceVariable(win_fn_ivar_name);
    try std.testing.expect(got_ctx.value != null);
    try std.testing.expect(got_fn.value != null);

    // Invoke dispatch: fn_ptr(bundle_ptr) → dispatchClose → callback(ctx) → fired=true.
    const recovered_fn: *const fn (*anyopaque) void = @ptrCast(@alignCast(got_fn.value));
    recovered_fn(got_ctx.value.?);
    try std.testing.expect(fired);
}

test "Window.setCloseHandler signature matches spec" {
    const params = @typeInfo(@TypeOf(Window.setCloseHandler)).@"fn".params;
    // self: *Window, ctx: *anyopaque, callback: *const fn(*anyopaque) void
    try std.testing.expectEqual(@as(usize, 3), params.len);
}

test {
    std.testing.refAllDecls(@This());
}
