//! Transparent drag-and-drop overlay for wkz windows.
//!
//! Responsibility: register a transparent NSView subclass (`WkzDragView`) above
//! the WKWebView that accepts file drags and emits a `dragdrop.filesDropped`
//! bridge event with the dropped file paths.
//!
//! **Design**: an overlay NSView whose `hitTest:` always returns `nil` is placed
//! above the WKWebView in the window's content view hierarchy. All mouse clicks
//! therefore fall through to the WKWebView below (the overlay is purely
//! invisible and input-transparent), while the `NSDraggingDestination` protocol
//! methods implemented on the overlay receive file drag-and-drop operations.
//!
//! **ARC**: `DragDrop` owns one `+1` reference to the overlay NSView (from
//! `alloc/initWithFrame:`). NSWindow's view hierarchy retains the overlay a
//! second time via `addSubview:positioned:relativeTo:` — that reference is
//! owned by the NSWindow, not by us. `deinit` calls `removeFromSuperview` then
//! `release` to drop our `+1`, leaving the refcount balanced.
//!
//! **No ObjC blocks.** File paths are delivered to JS via `bridge.evaluate`.
//! **Main thread only.** All AppKit calls happen on the main thread.

const std = @import("std");
const objc = @import("objc");
const c = objc.c;
const window = @import("window.zig");
const bridge_mod = @import("bridge.zig");

const log = std.log.scoped(.wkz_dragdrop);

/// Process-unique name for the `WkzDragView` NSView subclass.
const class_name: [:0]const u8 = "WkzDragView";

/// Name of the `id`-typed instance variable storing a borrowed `*DragDrop`.
const ivar_name: [:0]const u8 = "wkz_drag_ctx";

/// `NSDragOperation` constant for "copy". Returned from `draggingEntered:` and
/// `draggingUpdated:` to accept file drags with the copy badge.
const NSDragOperationCopy: c_ulong = 1;

/// Errors surfaced while initialising the drag-drop overlay.
pub const Error = error{
    /// A required AppKit class could not be looked up.
    ClassNotFound,
    /// `objc_allocateClassPair` returned nil (duplicate name or internal ObjC
    /// error). Should be unreachable after the idempotency guard.
    ClassRegistrationFailed,
} || std.mem.Allocator.Error;

/// Transparent drag-and-drop overlay attached to one window.
///
/// Ownership:
///   * `overlay` is a `+1` instance of `WkzDragView` (alloc/initWithFrame:),
///     owned by this struct and released by `deinit`.
///   * `bridge` is BORROWED (not +1). The caller keeps it alive.
///   * The context pointer written into the ivar is a raw borrow — no retain.
pub const DragDrop = struct {
    allocator: std.mem.Allocator,
    bridge: *bridge_mod.Bridge,
    /// Owned `+1` overlay NSView. Released by `deinit`.
    overlay: objc.Object,

    /// Create and attach a transparent file-drag overlay to `window`.
    ///
    /// Registers the `WkzDragView` class once per process (idempotent). On the
    /// error path nothing is leaked: `errdefer overlay.release` balances the
    /// `alloc/initWithFrame:` on every fallible step.
    ///
    /// `bridge` is borrowed — the caller must keep it alive for the lifetime of
    /// this `DragDrop`. Must be called on the main thread.
    pub fn init(
        allocator: std.mem.Allocator,
        win: window.Window,
        bridge: *bridge_mod.Bridge,
    ) Error!DragDrop {
        try registerClass();

        const NSString = objc.getClass("NSString") orelse return Error.ClassNotFound;
        const NSArray = objc.getClass("NSArray") orelse return Error.ClassNotFound;
        const WkzDragView = objc.getClass(class_name) orelse return Error.ClassNotFound;

        // Get the content view's bounds for the initial frame.
        const content_view = win.contentView();
        const bounds = content_view.msgSend(window.CGRect, "bounds", .{});

        // alloc/initWithFrame: -> +1 owned by this struct (released in deinit).
        const overlay = WkzDragView.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithFrame:", .{bounds});
        errdefer overlay.msgSend(void, "release", .{});

        // NSViewWidthSizable (2) | NSViewHeightSizable (16) = 18.
        // Keeps the overlay filling the content view when the window resizes.
        overlay.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, 18)});

        // Register for NSFilenamesPboardType file drags.
        // `stringWithUTF8String:` returns an autoreleased NSString — no +1,
        // no release needed here.
        const type_cstr: [:0]const u8 = "NSFilenamesPboardType";
        const ns_type = NSString.msgSend(
            objc.Object,
            "stringWithUTF8String:",
            .{type_cstr.ptr},
        );
        var types_arr = [1]objc.Object{ns_type};
        // `arrayWithObjects:count:` returns an autoreleased NSArray.
        const ns_types = NSArray.msgSend(
            objc.Object,
            "arrayWithObjects:count:",
            .{ &types_arr, @as(c_ulong, 1) },
        );
        overlay.msgSend(void, "registerForDraggedTypes:", .{ns_types});

        // Allocate the DragDrop on the heap so we can store a stable pointer in
        // the ivar. The overlay's IMP recovers this pointer; it must stay valid
        // for as long as the overlay is in the view hierarchy.
        const self_ptr = try allocator.create(DragDrop);
        errdefer allocator.destroy(self_ptr);

        self_ptr.* = .{
            .allocator = allocator,
            .bridge = bridge,
            .overlay = overlay,
        };

        // Store the heap pointer in the id-typed ivar (raw store, no retain).
        overlay.setInstanceVariable(ivar_name, .{ .value = @ptrCast(self_ptr) });

        // NSWindowAbove = 1: place the overlay above the WKWebView.
        // The third argument (relativeTo) is nil — c.id is already ?*anyopaque
        // (nullable), so we pass null directly rather than wrapping in ?c.id
        // (that would be ??*anyopaque which is not valid in C ABI msgSend).
        content_view.msgSend(
            void,
            "addSubview:positioned:relativeTo:",
            .{ overlay, @as(c_long, 1), @as(c.id, null) },
        );

        return self_ptr.*;
    }

    /// Remove the overlay from the view hierarchy and release the owned `+1`
    /// reference. Also frees the heap-allocated context that was stored in the
    /// ivar. Must be called on the main thread.
    pub fn deinit(self: DragDrop) void {
        // Recover and free the heap-allocated copy we created in init.
        const ctx_obj = self.overlay.getInstanceVariable(ivar_name);
        if (ctx_obj.value != null) {
            const heap_ptr: *DragDrop = @ptrCast(@alignCast(ctx_obj.value));
            // Clear the ivar before freeing to prevent a dangling reference if
            // the overlay were somehow messaged after this point.
            self.overlay.setInstanceVariable(ivar_name, .{ .value = null });
            self.allocator.destroy(heap_ptr);
        }
        self.overlay.msgSend(void, "removeFromSuperview", .{});
        self.overlay.msgSend(void, "release", .{});
    }
};

// =====================================================================
// ObjC class IMPs
// =====================================================================

/// Recover the `*DragDrop` stored in the overlay's context ivar.
/// Returns null if `attach` was never called (programming error).
fn recoverCtx(self_id: c.id) ?*DragDrop {
    const obj = objc.Object{ .value = self_id };
    const ctx = obj.getInstanceVariable(ivar_name);
    if (ctx.value == null) return null;
    return @ptrCast(@alignCast(ctx.value));
}

/// `-[WkzDragView draggingEntered:]` — tell AppKit we accept the drag.
fn impDraggingEntered(
    _: c.id,
    _: c.SEL,
    _: c.id,
) callconv(.c) c_ulong {
    return NSDragOperationCopy;
}

/// `-[WkzDragView draggingUpdated:]` — sustain acceptance as the drag moves.
fn impDraggingUpdated(
    _: c.id,
    _: c.SEL,
    _: c.id,
) callconv(.c) c_ulong {
    return NSDragOperationCopy;
}

/// `-[WkzDragView hitTest:]` — always return nil so all mouse events fall
/// through to the WKWebView below.
///
/// `c.id` is defined as `?*anyopaque` in zig-objc (c.zig). Returning `c.id`
/// with value `null` is the correct nil-object return for a C ABI IMP — no
/// wrapping `?c.id` needed (that would be `??*anyopaque`, invalid for C ABI).
fn impHitTest(
    _: c.id,
    _: c.SEL,
    _: window.CGPoint,
) callconv(.c) c.id {
    return null;
}

/// `-[WkzDragView performDragOperation:]` — extract file paths from the
/// pasteboard, build a JSON event, and push it to the bridge.
///
/// Returns `true` (operation accepted). ARC: all NSString/NSArray objects on
/// this path are autoreleased (returned by AppKit); we do not retain/release
/// them. The JSON string is allocated from `ctx.allocator` and freed after
/// `evaluate`.
fn impPerformDrag(
    self_id: c.id,
    _: c.SEL,
    info_id: c.id,
) callconv(.c) bool {
    const ctx = recoverCtx(self_id) orelse {
        log.warn("performDragOperation: no context (was DragDrop.init called?)", .{});
        return false;
    };

    // -[<id<NSDraggingInfo>> draggingPasteboard] -> autoreleased NSPasteboard.
    const info = objc.Object{ .value = info_id };
    const pboard = info.msgSend(objc.Object, "draggingPasteboard", .{});

    // Build the NSFilenamesPboardType constant string.
    const NSString = objc.getClass("NSString") orelse {
        log.warn("performDragOperation: NSString class not found", .{});
        return false;
    };
    const type_cstr: [:0]const u8 = "NSFilenamesPboardType";
    const ns_type = NSString.msgSend(
        objc.Object,
        "stringWithUTF8String:",
        .{type_cstr.ptr},
    );

    // -[NSPasteboard propertyListForType:] -> autoreleased NSArray of NSString,
    // or nil if the type is absent.
    const paths_obj = pboard.msgSend(objc.Object, "propertyListForType:", .{ns_type});
    if (paths_obj.value == null) return true;

    const count = paths_obj.msgSend(c_ulong, "count", .{});
    if (count == 0) return true;

    // Collect path strings into an ArrayList.
    // std.ArrayList in 0.16 is the unmanaged Aligned type: use `.empty` to
    // init, pass the allocator to append/deinit (array_list.zig:591,903,623).
    var path_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (path_list.items) |p| ctx.allocator.free(p);
        path_list.deinit(ctx.allocator);
    }

    var i: c_ulong = 0;
    while (i < count) : (i += 1) {
        const ns_path = paths_obj.msgSend(objc.Object, "objectAtIndex:", .{i});
        // -UTF8String returns a borrowed C string (owned by the NSString).
        const utf8 = ns_path.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse continue;
        // `std.mem.span` produces a slice over the borrowed memory; we copy
        // it into the allocator so it survives past the autorelease pool.
        const span = std.mem.span(utf8);
        const copy = ctx.allocator.dupe(u8, span) catch {
            log.warn("performDragOperation: OOM copying path", .{});
            continue;
        };
        path_list.append(ctx.allocator, copy) catch {
            ctx.allocator.free(copy);
            log.warn("performDragOperation: OOM appending path", .{});
            continue;
        };
    }

    // Build the event payload struct and serialize to JSON.
    const Payload = struct {
        paths: []const []const u8,
    };
    const Event = struct {
        type: []const u8,
        payload: Payload,
    };

    // std.json.Stringify.valueAlloc (json/Stringify.zig:618):
    //   pub fn valueAlloc(gpa, v, options) error{OutOfMemory}![]u8
    const json_str = std.json.Stringify.valueAlloc(
        ctx.allocator,
        Event{
            .type = "dragdrop.filesDropped",
            .payload = .{ .paths = path_list.items },
        },
        .{},
    ) catch {
        log.warn("performDragOperation: OOM building event JSON", .{});
        return true;
    };
    defer ctx.allocator.free(json_str);

    // Build the JS call: __wkz_event(<json>)
    // std.fmt.allocPrintSentinel (fmt.zig:639):
    //   pub fn allocPrintSentinel(gpa, comptime fmt, args, comptime sentinel) ![:sentinel]u8
    const js = std.fmt.allocPrintSentinel(
        ctx.allocator,
        "__wkz_event({s})",
        .{json_str},
        0,
    ) catch {
        log.warn("performDragOperation: OOM building JS call", .{});
        return true;
    };
    defer ctx.allocator.free(js);

    ctx.bridge.evaluate(js);
    return true;
}

// =====================================================================
// Class registration
// =====================================================================

/// Register (or look up) the `WkzDragView` NSView subclass. Idempotent —
/// calling this more than once returns the already-registered class. Must be
/// called on the main thread before any `DragDrop.init`.
///
/// Open-coded (not via `objc_helpers.defineClass`) because we need to add an
/// ivar before registration, matching the pattern used in `bridge.zig` for
/// `WkzScriptMessageHandler`.
fn registerClass() Error!void {
    // Idempotency guard: if already registered, nothing to do.
    if (objc.getClass(class_name) != null) return;

    const NSView = objc.getClass("NSView") orelse return Error.ClassNotFound;

    // `allocateClassPair` fails (nil) on duplicate name; we guarded above.
    const cls = objc.allocateClassPair(NSView, class_name) orelse
        return Error.ClassRegistrationFailed;

    // Ivars must be added before `registerClassPair`. `addIvar` adds an
    // `id`-typed (pointer-width) slot — zig-objc class.zig:91-95.
    std.debug.assert(cls.addIvar(ivar_name));

    // `addMethod` derives the type encoding from the IMP's fn type — no
    // hand-written encoding strings. zig-objc class.zig:72-87.
    std.debug.assert(cls.addMethod("draggingEntered:", impDraggingEntered));
    std.debug.assert(cls.addMethod("draggingUpdated:", impDraggingUpdated));
    std.debug.assert(cls.addMethod("performDragOperation:", impPerformDrag));
    std.debug.assert(cls.addMethod("hitTest:", impHitTest));

    objc.registerClassPair(cls);
}

// =====================================================================
// Tests
// =====================================================================

test "NSView class resolves in ObjC runtime" {
    try std.testing.expect(objc.getClass("NSView") != null);
}

test "NSView instances respond to required selectors" {
    const NSView = objc.getClass("NSView").?;
    const selectors = [_][:0]const u8{
        "initWithFrame:",
        "registerForDraggedTypes:",
        "addSubview:positioned:relativeTo:",
        "setAutoresizingMask:",
        "hitTest:",
        "bounds",
        "removeFromSuperview",
    };
    inline for (selectors) |sel| {
        const responds = NSView.msgSend(
            bool,
            "instancesRespondToSelector:",
            .{objc.sel(sel).value},
        );
        try std.testing.expect(responds);
    }
}

test "WkzDragView class registration is idempotent" {
    // First registration.
    try registerClass();
    const a = objc.getClass(class_name);
    try std.testing.expect(a != null);

    // Second call — must not panic or return an error.
    try registerClass();
    const b = objc.getClass(class_name);
    try std.testing.expect(b != null);

    // Both lookups return the same class object.
    try std.testing.expectEqual(a.?.value, b.?.value);

    // The class responds to the selectors we registered.
    const cls = a.?;
    for ([_][:0]const u8{
        "draggingEntered:",
        "draggingUpdated:",
        "performDragOperation:",
        "hitTest:",
    }) |sel| {
        try std.testing.expect(cls.msgSend(
            bool,
            "instancesRespondToSelector:",
            .{objc.sel(sel).value},
        ));
    }
}

test "NSPasteboard instances respond to propertyListForType:" {
    const NSPasteboard = objc.getClass("NSPasteboard") orelse return;
    try std.testing.expect(NSPasteboard.msgSend(
        bool,
        "instancesRespondToSelector:",
        .{objc.sel("propertyListForType:").value},
    ));
}

test {
    std.testing.refAllDecls(@This());
}
