//! NSWindow creation and configuration.
//!
//! Responsibility: build an NSWindow (titled, closable, resizable), center it
//! on screen, set its title, and bring it to front via makeKeyAndOrderFront.
//! The window's contentView is later filled by the WKWebView (M1.4). Main
//! thread only.

const std = @import("std");
const objc = @import("objc");

/// `NSWindowStyleMask` flag values (AppKit/NSWindow.h). Stable since 10.0.
/// Combined into the style mask passed to `initWithContentRect:...`.
const NSWindowStyleMaskTitled: c_ulong = 1 << 0;
const NSWindowStyleMaskClosable: c_ulong = 1 << 1;
const NSWindowStyleMaskResizable: c_ulong = 1 << 3;

/// `NSBackingStoreType` value (AppKit/NSGraphics.h). `Buffered` is the only
/// backing store store supported on modern macOS.
const NSBackingStoreBuffered: c_ulong = 2;

/// `CGFloat` on 64-bit Apple platforms is a `double`. NSWindow geometry is
/// expressed in these.
const CGFloat = f64;

/// `CGPoint` / `NSPoint`: the origin of a rect, in points.
/// `extern struct` so it is passed by value over the C ABI by zig-objc's
/// msgSend (which requires extern/packed layout for struct arguments).
const CGPoint = extern struct {
    x: CGFloat,
    y: CGFloat,
};

/// `CGSize` / `NSSize`: the extent of a rect, in points.
const CGSize = extern struct {
    width: CGFloat,
    height: CGFloat,
};

/// `CGRect` / `NSRect`: the content rectangle handed to NSWindow. 32 bytes
/// (4 × f64); zig-objc selects the correct objc_msgSend variant for the size
/// and architecture automatically.
const CGRect = extern struct {
    origin: CGPoint,
    size: CGSize,
};

/// Errors surfaced while creating a window.
pub const Error = error{
    /// A required AppKit class could not be looked up in the runtime. This
    /// only happens if AppKit failed to link/load, which is fatal.
    ClassNotFound,
};

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

    /// Release the owned NSWindow reference. After this the `Window` is dead.
    /// Must be called on the main thread.
    pub fn deinit(self: Window) void {
        self.ns_window.msgSend(void, "release", .{});
    }

    /// Replace the window's title. `title` is copied by NSWindow; the transient
    /// NSString built here is released. Must be called on the main thread.
    pub fn setTitle(self: Window, title: [:0]const u8) Error!void {
        const NSString = objc.getClass("NSString") orelse return Error.ClassNotFound;
        const ns_title = nsString(NSString, title);
        defer ns_title.msgSend(void, "release", .{});
        self.ns_window.msgSend(void, "setTitle:", .{ns_title});
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

test {
    std.testing.refAllDecls(@This());
}
