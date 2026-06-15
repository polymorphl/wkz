const std = @import("std");
const objc = @import("objc");
const Bridge = @import("bridge.zig").Bridge;

const c = objc.c;
const log = std.log.scoped(.wkz_statusitem);

/// NSStatusBar item managed through the JS bridge.
///
/// Ownership:
///   - `item` is a `+1` NSStatusItem (retained from `statusItemWithLength:`),
///     released by `deinit`.
///   - `target` is a `+1` `WkzStatusItemTarget` instance, released by `deinit`.
///   - `bridge` is BORROWED — must outlive this struct.
///
/// Call `registerBridgeHandlers` once after `init` to wire JS handlers.
/// Must be created and used on the main thread.
pub const StatusItem = struct {
    allocator: std.mem.Allocator,
    bridge: *Bridge,
    item: ?objc.Object = null,
    target: ?objc.Object = null,

    /// Create a `StatusItem` bound to `bridge`.
    /// No NSStatusBar item is created yet — call `registerBridgeHandlers` to
    /// wire the JS handlers, then let JS call `statusitem.set` to show the item.
    /// `bridge` must outlive this struct.
    pub fn init(allocator: std.mem.Allocator, bridge: *Bridge) StatusItem {
        return .{ .allocator = allocator, .bridge = bridge };
    }

    /// Releases the retained NSStatusItem and WkzStatusItemTarget.
    /// Must be called before app exits.
    pub fn deinit(self: *StatusItem) void {
        if (self.item) |item| {
            item.msgSend(void, "release", .{});
            self.item = null;
        }
        if (self.target) |target| {
            target.msgSend(void, "release", .{});
            self.target = null;
        }
    }

    /// Registers statusitem.set and statusitem.remove on bridge.
    /// Sets bridge.context — do NOT combine with Fs or Updater on the same bridge.
    pub fn registerBridgeHandlers(self: *StatusItem, bridge: *Bridge) !void {
        std.debug.assert(self.bridge == bridge); // must match the bridge passed to init
        bridge.context = @ptrCast(self);
        try bridge.registerHandler("statusitem.set", handleSet);
        try bridge.registerHandler("statusitem.remove", handleRemove);
    }
};

// ── ObjC class ───────────────────────────────────────────────────────────────

/// Create (or look up) the WkzStatusItemTarget class.
/// Idempotent — safe to call multiple times.
fn statusItemTargetClass() error{ClassNotFound}!objc.Class {
    if (objc.getClass("WkzStatusItemTarget")) |existing| return existing;

    const NSObject = objc.getClass("NSObject") orelse return error.ClassNotFound;
    const cls = objc.allocateClassPair(NSObject, "WkzStatusItemTarget") orelse
        return error.ClassNotFound;

    // Ivars must be added between allocateClassPair and registerClassPair.
    std.debug.assert(cls.addIvar("wkz_ctx"));
    std.debug.assert(cls.addMethod("itemClicked:", impItemClicked));

    objc.registerClassPair(cls);
    return cls;
}

fn impItemClicked(self_id: c.id, _cmd: c.SEL, _sender: c.id) callconv(.c) void {
    _ = _cmd;
    _ = _sender;
    const self_obj = objc.Object{ .value = self_id };
    const raw = self_obj.getInstanceVariable("wkz_ctx");
    if (raw.value == null) return;
    const si: *StatusItem = @ptrCast(@alignCast(raw.value));
    emitClick(si);
}

fn emitClick(self: *StatusItem) void {
    self.bridge.evaluate(
        "window.__wkz_event({\"type\":\"statusitem.click\",\"payload\":{}})",
    );
}

// ── Handlers ─────────────────────────────────────────────────────────────────

fn handleSet(bridge: *Bridge, params: std.json.Value, id: ?i64) void {
    const self: *StatusItem = @ptrCast(@alignCast(bridge.context orelse {
        log.warn("statusitem.set: no context on bridge", .{});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    }));

    const obj = switch (params) {
        .object => |o| o,
        else => {
            log.warn("statusitem.set: params must be a JSON object", .{});
            if (id) |i| bridge.resolve(i, "null") catch {};
            return;
        },
    };

    // Extract optional title and icon strings.
    const title: ?[]const u8 = blk: {
        const v = obj.get("title") orelse break :blk null;
        break :blk switch (v) {
            .string => |s| s,
            else => null,
        };
    };
    const icon: ?[]const u8 = blk: {
        const v = obj.get("icon") orelse break :blk null;
        break :blk switch (v) {
            .string => |s| s,
            else => null,
        };
    };

    if (title == null and icon == null) {
        log.warn("statusitem.set: at least one of title or icon must be present", .{});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    }

    // Create the status item on first call.
    if (self.item == null) {
        const NSStatusBar = objc.getClass("NSStatusBar") orelse {
            log.warn("statusitem.set: NSStatusBar class not found", .{});
            if (id) |i| bridge.resolve(i, "null") catch {};
            return;
        };

        // systemStatusBar → autoreleased, NOT retained.
        const bar = NSStatusBar.msgSend(objc.Object, "systemStatusBar", .{});

        // statusItemWithLength: → +0 (bar is owner); retain to get our +1.
        const item = bar.msgSend(objc.Object, "statusItemWithLength:", .{@as(f64, -1.0)})
            .msgSend(objc.Object, "retain", .{});
        self.item = item;

        // Create WkzStatusItemTarget instance → +1.
        const cls = statusItemTargetClass() catch {
            log.warn("statusitem.set: failed to create WkzStatusItemTarget class", .{});
            // Release the item we just retained.
            item.msgSend(void, "release", .{});
            self.item = null;
            if (id) |i| bridge.resolve(i, "null") catch {};
            return;
        };
        const target = cls.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "init", .{});
        target.setInstanceVariable("wkz_ctx", .{ .value = @ptrCast(self) });
        self.target = target;

        // Wire target-action on the button.
        // NSStatusButton.setTarget: stores a WEAK reference (does NOT retain).
        // self.target holds the only +1.
        const button = item.msgSend(objc.Object, "button", .{});
        button.msgSend(void, "setTarget:", .{target});
        button.msgSend(void, "setAction:", .{objc.sel("itemClicked:").value});
    }

    const NSString = objc.getClass("NSString") orelse {
        log.warn("statusitem.set: NSString class not found", .{});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    };

    // button is a weak/autoreleased property — NOT retained.
    const button = self.item.?.msgSend(objc.Object, "button", .{});

    // Set title if present.
    if (title) |t| {
        const z = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{t}, 0) catch {
            log.warn("statusitem.set: OOM allocating title NSString", .{});
            if (id) |i| bridge.resolve(i, "null") catch {};
            return;
        };
        defer self.allocator.free(z);
        const ns = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{z.ptr})
            .msgSend(objc.Object, "retain", .{});
        defer ns.msgSend(void, "release", .{});
        button.msgSend(void, "setTitle:", .{ns});
    }

    // Set SF Symbol icon if present.
    if (icon) |sym| {
        const NSImage = objc.getClass("NSImage") orelse {
            log.warn("statusitem.set: NSImage class not found, skipping icon", .{});
            if (id) |i| bridge.resolve(i, "null") catch {};
            return;
        };

        const z = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{sym}, 0) catch {
            log.warn("statusitem.set: OOM allocating icon NSString", .{});
            if (id) |i| bridge.resolve(i, "null") catch {};
            return;
        };
        defer self.allocator.free(z);
        const ns_name = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{z.ptr})
            .msgSend(objc.Object, "retain", .{});
        defer ns_name.msgSend(void, "release", .{});

        // imageWithSystemSymbolName:accessibilityDescription: requires macOS 12+.
        // Returns nil for unknown symbol or older OS — skip with warn.
        const ns_image = NSImage.msgSend(
            objc.Object,
            "imageWithSystemSymbolName:accessibilityDescription:",
            .{ ns_name, @as(?*anyopaque, null) },
        );
        if (ns_image.value == null) {
            log.warn("statusitem.set: SF Symbol '{s}' not found or macOS < 12, skipping icon", .{sym});
        } else {
            // Button retains the image — we do NOT retain it.
            button.msgSend(void, "setImage:", .{ns_image});
        }
    }

    if (id) |i| bridge.resolve(i, "null") catch {};
}

fn handleRemove(bridge: *Bridge, _params: std.json.Value, id: ?i64) void {
    _ = _params;
    const self: *StatusItem = @ptrCast(@alignCast(bridge.context orelse {
        log.warn("statusitem.remove: no context on bridge", .{});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    }));

    if (self.item == null) {
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    }

    const NSStatusBar = objc.getClass("NSStatusBar") orelse {
        log.warn("statusitem.remove: NSStatusBar class not found", .{});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    };
    const bar = NSStatusBar.msgSend(objc.Object, "systemStatusBar", .{});
    bar.msgSend(void, "removeStatusItem:", .{self.item.?});

    self.item.?.msgSend(void, "release", .{});
    self.item = null;
    if (self.target) |target| {
        target.msgSend(void, "release", .{});
        self.target = null;
    }

    if (id) |i| bridge.resolve(i, "null") catch {};
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "NSStatusBar class resolves in ObjC runtime" {
    try std.testing.expect(objc.getClass("NSStatusBar") != null);
}

test "NSStatusBar instances respond to required selectors" {
    const NSStatusBar = objc.getClass("NSStatusBar").?;
    try std.testing.expect(NSStatusBar.msgSend(
        bool,
        "respondsToSelector:",
        .{objc.sel("systemStatusBar").value},
    ));
    inline for ([_][:0]const u8{ "statusItemWithLength:", "removeStatusItem:" }) |sel| {
        try std.testing.expect(NSStatusBar.msgSend(
            bool,
            "instancesRespondToSelector:",
            .{objc.sel(sel).value},
        ));
    }
}

test "NSStatusItem instances respond to required selectors" {
    const NSStatusBar = objc.getClass("NSStatusBar").?;
    const bar = NSStatusBar.msgSend(objc.Object, "systemStatusBar", .{});
    const item = bar.msgSend(objc.Object, "statusItemWithLength:", .{@as(f64, -1.0)})
        .msgSend(objc.Object, "retain", .{});
    defer item.msgSend(void, "release", .{});
    inline for ([_][:0]const u8{ "button", "retain", "release" }) |sel| {
        try std.testing.expect(item.msgSend(
            bool,
            "respondsToSelector:",
            .{objc.sel(sel).value},
        ));
    }
}

test "statusItemTargetClass registers WkzStatusItemTarget with itemClicked: selector" {
    _ = try statusItemTargetClass();
    const cls = try statusItemTargetClass();
    try std.testing.expect(objc.getClass("WkzStatusItemTarget") != null);
    try std.testing.expect(cls.msgSend(
        bool,
        "instancesRespondToSelector:",
        .{objc.sel("itemClicked:").value},
    ));
}

test "registerBridgeHandlers registers statusitem.set and statusitem.remove" {
    var b = try Bridge.init(
        std.testing.allocator,
        objc.Object{ .value = null },
        objc.Object{ .value = null },
    );
    defer b.deinit();
    var si = StatusItem.init(std.testing.allocator, &b);
    defer si.deinit();
    try si.registerBridgeHandlers(&b);
    try std.testing.expectEqual(@as(u32, 2), b.dispatch.count());
    try std.testing.expect(b.dispatch.contains("statusitem.set"));
    try std.testing.expect(b.dispatch.contains("statusitem.remove"));
}
