const std = @import("std");
const objc = @import("objc");
const Bridge = @import("bridge.zig").Bridge;

const log = std.log.scoped(.wkz_alert);

/// Register the alert.show bridge handler on `bridge`.
/// Does NOT set bridge.context — safe to call alongside
/// Fs.registerBridgeHandlers and Updater.registerBridgeHandlers.
pub fn registerAlertHandler(bridge: *Bridge) !void {
    try bridge.registerHandler("alert.show", handleShow);
}

/// Open a native NSAlert modal and resolve with {"button":"<label>"} for the
/// clicked button, or "null" on missing title or unexpected runModal response.
///
/// Params (JSON object):
///   title    string   required — alert headline (messageText)
///   message  string   optional — body text (informativeText), default ""
///   style    string   optional — "warning" | "informational" | "critical", default "warning"
///   buttons  string[] optional — button labels, default ["OK"], max 3
///
/// Uses std.heap.page_allocator for ephemeral NSString and JSON allocations.
/// All memory is freed before return.
fn handleShow(bridge: *Bridge, params: std.json.Value, id: ?i64) void {
    const gpa = std.heap.page_allocator;

    // params must be a JSON object
    const obj = switch (params) {
        .object => |o| o,
        else => {
            log.warn("alert.show: params must be a JSON object", .{});
            if (id) |i| bridge.resolve(i, "null") catch {};
            return;
        },
    };

    // title is required
    const title: []const u8 = switch (obj.get("title") orelse {
        log.warn("alert.show: missing required title param", .{});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    }) {
        .string => |s| s,
        else => {
            log.warn("alert.show: title must be a string", .{});
            if (id) |i| bridge.resolve(i, "null") catch {};
            return;
        },
    };

    // message is optional, default ""
    const message: []const u8 = blk: {
        const v = obj.get("message") orelse break :blk "";
        break :blk switch (v) {
            .string => |s| s,
            else => "",
        };
    };

    // style: "warning"=0, "informational"=1, "critical"=2 (NSAlertStyle is NSUInteger = c_ulong)
    const alert_style: c_ulong = blk: {
        const v = obj.get("style") orelse break :blk 0;
        const s = switch (v) {
            .string => |s| s,
            else => break :blk 0,
        };
        if (std.mem.eql(u8, s, "warning")) break :blk 0;
        if (std.mem.eql(u8, s, "informational")) break :blk 1;
        if (std.mem.eql(u8, s, "critical")) break :blk 2;
        log.warn("alert.show: unknown style '{s}', defaulting to warning", .{s});
        break :blk 0;
    };

    // buttons: collect string labels, max 3, default ["OK"]
    var btn_buf: [3][]const u8 = undefined;
    var btn_count: usize = 0;
    if (obj.get("buttons")) |bv| {
        if (bv == .array) {
            for (bv.array.items) |item| {
                if (btn_count >= 3) {
                    log.warn("alert.show: buttons capped at 3 (AppKit max), ignoring remaining", .{});
                    break;
                }
                if (item == .string) {
                    btn_buf[btn_count] = item.string;
                    btn_count += 1;
                }
            }
        }
    }
    if (btn_count == 0) {
        btn_buf[0] = "OK";
        btn_count = 1;
    }
    const buttons = btn_buf[0..btn_count];

    const NSAlert = objc.getClass("NSAlert") orelse {
        log.warn("alert.show: NSAlert class not found in ObjC runtime", .{});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    };
    const NSString = objc.getClass("NSString") orelse {
        log.warn("alert.show: NSString class not found in ObjC runtime", .{});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    };

    // [[NSAlert alloc] init] → +1 reference, must release.
    const alert = NSAlert.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer alert.msgSend(void, "release", .{});

    // setMessageText: — sentinel-terminated NSString copy
    {
        const z = std.fmt.allocPrintSentinel(gpa, "{s}", .{title}, 0) catch {
            log.warn("alert.show: OOM allocating title NSString", .{});
            if (id) |i| bridge.resolve(i, "null") catch {};
            return;
        };
        defer gpa.free(z);
        const ns = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{z.ptr})
            .msgSend(objc.Object, "retain", .{});
        defer ns.msgSend(void, "release", .{});
        alert.msgSend(void, "setMessageText:", .{ns});
    }

    // setInformativeText: — only if non-empty
    if (message.len > 0) {
        const z = std.fmt.allocPrintSentinel(gpa, "{s}", .{message}, 0) catch {
            log.warn("alert.show: OOM allocating message NSString", .{});
            if (id) |i| bridge.resolve(i, "null") catch {};
            return;
        };
        defer gpa.free(z);
        const ns = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{z.ptr})
            .msgSend(objc.Object, "retain", .{});
        defer ns.msgSend(void, "release", .{});
        alert.msgSend(void, "setInformativeText:", .{ns});
    }

    // setAlertStyle: (NSUInteger / c_ulong)
    alert.msgSend(void, "setAlertStyle:", .{alert_style});

    // addButtonWithTitle: for each label
    for (buttons) |label| {
        const z = std.fmt.allocPrintSentinel(gpa, "{s}", .{label}, 0) catch {
            log.warn("alert.show: OOM allocating button NSString", .{});
            if (id) |i| bridge.resolve(i, "null") catch {};
            return;
        };
        defer gpa.free(z);
        const ns = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{z.ptr})
            .msgSend(objc.Object, "retain", .{});
        defer ns.msgSend(void, "release", .{});
        alert.msgSend(void, "addButtonWithTitle:", .{ns});
    }

    // runModal blocks the main thread. NSModalResponse = NSInteger = c_long.
    // First button → 1000, second → 1001, third → 1002.
    const response = alert.msgSend(c_long, "runModal", .{});
    const idx_raw = response - 1000;
    if (idx_raw < 0 or idx_raw >= @as(c_long, @intCast(btn_count))) {
        log.warn("alert.show: unexpected runModal response {}", .{response});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    }
    const idx: usize = @intCast(idx_raw);

    const json = std.json.Stringify.valueAlloc(
        gpa,
        .{ .button = buttons[idx] },
        .{},
    ) catch {
        log.warn("alert.show: json serialization failed (OOM)", .{});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    };
    defer gpa.free(json);
    if (id) |i| bridge.resolve(i, json) catch {};
}

test "NSAlert class resolves in ObjC runtime" {
    try std.testing.expect(objc.getClass("NSAlert") != null);
}

test "NSAlert instances respond to required selectors" {
    const NSAlert = objc.getClass("NSAlert").?;
    try std.testing.expect(NSAlert.msgSend(bool, "respondsToSelector:", .{objc.sel("alloc").value}));
    const instance_selectors = [_][:0]const u8{
        "runModal",
        "addButtonWithTitle:",
        "setMessageText:",
        "setInformativeText:",
        "setAlertStyle:",
    };
    inline for (instance_selectors) |name| {
        try std.testing.expect(NSAlert.msgSend(
            bool,
            "instancesRespondToSelector:",
            .{objc.sel(name).value},
        ));
    }
}

test "registerAlertHandler registers alert.show" {
    var b = try Bridge.init(
        std.testing.allocator,
        objc.Object{ .value = null },
        objc.Object{ .value = null },
    );
    defer b.deinit();
    try registerAlertHandler(&b);
    try std.testing.expectEqual(@as(u32, 1), b.dispatch.count());
    try std.testing.expect(b.dispatch.contains("alert.show"));
}
