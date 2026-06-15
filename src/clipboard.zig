const std = @import("std");
const objc = @import("objc");
const Bridge = @import("bridge.zig").Bridge;

const log = std.log.scoped(.wkz_clipboard);

/// NSPasteboardTypeString constant — the UTI for plain text on the macOS
/// general pasteboard. This is the value of the NSPasteboardTypeString symbol
/// without linking AppKit symbols.
const pasteboard_type_string: [:0]const u8 = "public.utf8-plain-text";

/// Register the clipboard.readText and clipboard.writeText bridge handlers on
/// `bridge`. No struct needed — no mutable state; uses page_allocator internally.
///
/// Call once at startup after bridge.attach().
pub fn registerClipboardHandlers(bridge: *Bridge) !void {
    try bridge.registerHandler("clipboard.readText", handleReadText);
    try bridge.registerHandler("clipboard.writeText", handleWriteText);
}

/// clipboard.readText — no params.
///
/// Reads the current text content from the general pasteboard.
/// Resolves with {"text":"<string>"} if text is present, or "null" if the
/// pasteboard holds no text.
///
/// ARC notes:
///   - NSPasteboard.generalPasteboard is a singleton — do NOT release.
///   - ns_type from stringWithUTF8String: is autoreleased — do NOT release.
///   - ns_str from stringForType: is autoreleased — do NOT release.
///   - UTF8String returns a C string borrowed from the NSString — do NOT free.
fn handleReadText(bridge: *Bridge, _: std.json.Value, id: ?i64) void {
    const gpa = std.heap.page_allocator;

    const NSPasteboard = objc.getClass("NSPasteboard") orelse {
        log.warn("clipboard.readText: NSPasteboard class not found in ObjC runtime", .{});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    };
    const NSString = objc.getClass("NSString") orelse {
        log.warn("clipboard.readText: NSString class not found in ObjC runtime", .{});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    };

    // Singleton — do NOT release.
    const pb = NSPasteboard.msgSend(objc.Object, "generalPasteboard", .{});

    // Autoreleased NSString for the type UTI — do NOT release.
    const ns_type = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{pasteboard_type_string.ptr});

    // Autoreleased NSString (or nil) from the pasteboard — do NOT release.
    const ns_str = pb.msgSend(objc.Object, "stringForType:", .{ns_type});
    if (ns_str.value == null) {
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    }

    // Borrowed C string from the NSString — do NOT free.
    const cstr = ns_str.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse {
        log.warn("clipboard.readText: UTF8String returned null", .{});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    };
    const text = std.mem.span(cstr);

    const json = std.json.Stringify.valueAlloc(
        gpa,
        .{ .text = text },
        .{},
    ) catch {
        log.warn("clipboard.readText: json serialization failed (OOM)", .{});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    };
    defer gpa.free(json);
    if (id) |i| bridge.resolve(i, json) catch {};
}

/// clipboard.writeText — params: { text: string }.
///
/// Writes the given text string to the general pasteboard.
/// Resolves with "null" (fire-and-forget from the JS perspective).
///
/// ARC notes:
///   - NSPasteboard.generalPasteboard is a singleton — do NOT release.
///   - ns_type from stringWithUTF8String: is autoreleased — do NOT release.
///   - ns_text from stringWithUTF8String: is autoreleased — do NOT release.
///   - The sentinel-terminated copy of text (text_z) is freed after the
///     stringWithUTF8String: call because the NSString copies the bytes.
fn handleWriteText(bridge: *Bridge, params: std.json.Value, id: ?i64) void {
    const gpa = std.heap.page_allocator;

    const obj = switch (params) {
        .object => |o| o,
        else => {
            log.warn("clipboard.writeText: params must be a JSON object", .{});
            if (id) |i| bridge.resolve(i, "null") catch {};
            return;
        },
    };

    const text: []const u8 = switch (obj.get("text") orelse {
        log.warn("clipboard.writeText: missing required text param", .{});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    }) {
        .string => |s| s,
        else => {
            log.warn("clipboard.writeText: text must be a string", .{});
            if (id) |i| bridge.resolve(i, "null") catch {};
            return;
        },
    };

    const NSPasteboard = objc.getClass("NSPasteboard") orelse {
        log.warn("clipboard.writeText: NSPasteboard class not found in ObjC runtime", .{});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    };
    const NSString = objc.getClass("NSString") orelse {
        log.warn("clipboard.writeText: NSString class not found in ObjC runtime", .{});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    };

    // Singleton — do NOT release.
    const pb = NSPasteboard.msgSend(objc.Object, "generalPasteboard", .{});

    // Autoreleased NSString for the type UTI — do NOT release.
    const ns_type = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{pasteboard_type_string.ptr});

    // Build a sentinel-terminated copy to hand to stringWithUTF8String:,
    // which copies the bytes. Free after the call.
    const text_z = std.fmt.allocPrintSentinel(gpa, "{s}", .{text}, 0) catch {
        log.warn("clipboard.writeText: OOM allocating text NSString", .{});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    };
    defer gpa.free(text_z);

    // Autoreleased NSString — do NOT release.
    const ns_text = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{text_z.ptr});

    pb.msgSend(void, "clearContents", .{});
    _ = pb.msgSend(bool, "setString:forType:", .{ ns_text, ns_type });

    if (id) |i| bridge.resolve(i, "null") catch {};
}

// =====================================================================
// Tests
// =====================================================================

test "NSPasteboard class resolves in ObjC runtime" {
    try std.testing.expect(objc.getClass("NSPasteboard") != null);
}

test "NSPasteboard instances respond to required selectors" {
    const NSPasteboard = objc.getClass("NSPasteboard").?;
    // generalPasteboard is a class method.
    try std.testing.expect(NSPasteboard.msgSend(
        bool,
        "respondsToSelector:",
        .{objc.sel("generalPasteboard").value},
    ));
    // Instance methods.
    const instance_selectors = [_][:0]const u8{
        "stringForType:",
        "setString:forType:",
        "clearContents",
    };
    inline for (instance_selectors) |name| {
        try std.testing.expect(NSPasteboard.msgSend(
            bool,
            "instancesRespondToSelector:",
            .{objc.sel(name).value},
        ));
    }
}

test "registerClipboardHandlers registers exactly 2 handlers" {
    var bridge = try Bridge.init(
        std.testing.allocator,
        objc.Object{ .value = null },
        objc.Object{ .value = null },
    );
    defer bridge.deinit();
    try registerClipboardHandlers(&bridge);
    try std.testing.expectEqual(@as(u32, 2), bridge.dispatch.count());
    try std.testing.expect(bridge.dispatch.contains("clipboard.readText"));
    try std.testing.expect(bridge.dispatch.contains("clipboard.writeText"));
}

test "clipboard read/write round-trip via bridge handlers" {
    // Wire a headless bridge (nil ucc/webview — messaging nil is a no-op in ObjC,
    // so deinit's removeScriptMessageHandlerForName: and bridge.resolve's
    // evaluateJavaScript: against nil are both safe no-ops headlessly).
    var bridge = try Bridge.init(
        std.testing.allocator,
        objc.Object{ .value = null },
        objc.Object{ .value = null },
    );
    defer bridge.deinit();
    try registerClipboardHandlers(&bridge);

    const sentinel = "hello wkz clipboard";

    // Write the sentinel text by calling the handler directly with crafted params.
    // We call handleWriteText via dispatchSlice so the full handler path runs.
    try bridge.dispatchSlice(
        \\{"method":"clipboard.writeText","params":{"text":"hello wkz clipboard"}}
    );

    // Verify the pasteboard state directly via ObjC: read back the text the
    // handler just wrote. This is the ground truth — no need to intercept
    // bridge.resolve (which goes to a nil webview and is a no-op headlessly).
    const NSPasteboard = objc.getClass("NSPasteboard").?;
    const NSString = objc.getClass("NSString").?;
    const pb = NSPasteboard.msgSend(objc.Object, "generalPasteboard", .{});
    const ns_type = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{pasteboard_type_string.ptr});
    const ns_result = pb.msgSend(objc.Object, "stringForType:", .{ns_type});
    // The pasteboard must now hold the sentinel text.
    try std.testing.expect(ns_result.value != null);
    const cstr = ns_result.msgSend(?[*:0]const u8, "UTF8String", .{});
    try std.testing.expect(cstr != null);
    const got = std.mem.span(cstr.?);
    try std.testing.expectEqualStrings(sentinel, got);

    // Confirm readText dispatches without panicking (resolve is a no-op on nil
    // webview; the handler runs the full ObjC path headlessly).
    try bridge.dispatchSlice(
        \\{"method":"clipboard.readText","id":1}
    );
}
