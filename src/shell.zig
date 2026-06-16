//! Shell integration bridge handlers.
//!
//! Responsibility: register bridge handlers that invoke macOS system services
//! via NSWorkspace. Currently exposes `shell.open` which opens a URL in the
//! default browser (or any registered URL handler) via
//! `+[NSWorkspace sharedWorkspace]` → `-[NSWorkspace openURL:]`.
//!
//! Main thread only (NSWorkspace is AppKit). No ARC: class-method results
//! (`sharedWorkspace`, `URLWithString:`, `stringWithUTF8String:`) are all
//! autoreleased — we do NOT release them.

const std = @import("std");
const objc = @import("objc");
const Bridge = @import("bridge.zig").Bridge;

const log = std.log.scoped(.wkz_shell);

/// Register the `shell.open` bridge handler on `bridge`.
///
/// Call once at startup after `bridge.attach()`. No mutable module state is
/// needed — `registerHandler` records only a plain function pointer.
///
/// Returns `Allocator.Error` if the dispatch table cannot grow.
pub fn registerHandlers(bridge: *Bridge) std.mem.Allocator.Error!void {
    try bridge.registerHandler("shell.open", handleOpen);
}

/// shell.open — params: a JSON string containing the URL to open.
///
/// Example JS call:
/// ```js
/// invoke("shell.open", "https://example.com")
/// ```
///
/// The handler opens the URL in the default system handler for that scheme
/// (browser for `https://`, mail client for `mailto:`, etc.) via
/// `+[NSWorkspace sharedWorkspace]` → `-[NSWorkspace openURL:]`.
///
/// Resolves with `"true"` once the URL is dispatched to the OS. Resolves with
/// `"false"` on param errors or unparseable URLs. The `openURL:` return value
/// is not used — macOS returns NO for async launches even on success.
///
/// ARC notes:
///   - `sharedWorkspace` is a singleton — do NOT release.
///   - `stringWithUTF8String:` returns an autoreleased NSString — do NOT release.
///   - `URLWithString:` returns an autoreleased NSURL — do NOT release.
///   - `url_z` (sentinel-terminated Zig copy) is freed after the
///     `stringWithUTF8String:` call because the NSString copies the bytes.
fn handleOpen(bridge: *Bridge, params: std.json.Value, id: ?i64) void {
    const gpa = bridge.allocator;

    // params must be a JSON string holding the URL.
    const url_str: []const u8 = switch (params) {
        .string => |s| s,
        else => {
            log.warn("shell.open: params must be a JSON string (the URL)", .{});
            if (id) |i| bridge.resolve(i, "false") catch {};
            return;
        },
    };

    const NSString = objc.getClass("NSString") orelse {
        log.warn("shell.open: NSString class not found in ObjC runtime", .{});
        if (id) |i| bridge.resolve(i, "false") catch {};
        return;
    };
    const NSURL = objc.getClass("NSURL") orelse {
        log.warn("shell.open: NSURL class not found in ObjC runtime", .{});
        if (id) |i| bridge.resolve(i, "false") catch {};
        return;
    };
    const NSWorkspace = objc.getClass("NSWorkspace") orelse {
        log.warn("shell.open: NSWorkspace class not found in ObjC runtime", .{});
        if (id) |i| bridge.resolve(i, "false") catch {};
        return;
    };

    // Build a NUL-terminated copy to hand to stringWithUTF8String:
    // (which copies the bytes). Free after the call.
    const url_z = std.fmt.allocPrintSentinel(gpa, "{s}", .{url_str}, 0) catch {
        log.warn("shell.open: OOM building URL NSString", .{});
        if (id) |i| bridge.resolve(i, "false") catch {};
        return;
    };
    defer gpa.free(url_z);

    // Autoreleased NSString for the URL string — do NOT release.
    const ns_str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{url_z.ptr});

    // Autoreleased NSURL — do NOT release. Returns nil for a malformed URL.
    const nsurl = NSURL.msgSend(objc.Object, "URLWithString:", .{ns_str});
    if (nsurl.value == null) {
        log.warn("shell.open: NSURL URLWithString: returned nil for \"{s}\"", .{url_str});
        if (id) |i| bridge.resolve(i, "false") catch {};
        return;
    }

    // Singleton NSWorkspace — do NOT release.
    const workspace = NSWorkspace.msgSend(objc.Object, "sharedWorkspace", .{});

    // -[NSWorkspace openURL:] opens the URL with the registered default handler.
    // Return value is unreliable on macOS (async launch returns NO even on success)
    // — resolve "true" if we reach this point (NSURL was well-formed).
    _ = workspace.msgSend(objc.Object, "openURL:", .{nsurl});

    if (id) |i| bridge.resolve(i, "true") catch {};
}

// =====================================================================
// Tests
// =====================================================================

test "NSWorkspace class resolves in ObjC runtime" {
    try std.testing.expect(objc.getClass("NSWorkspace") != null);
}

test "NSWorkspace responds to sharedWorkspace and openURL:" {
    const NSWorkspace = objc.getClass("NSWorkspace").?;
    // sharedWorkspace is a class method.
    try std.testing.expect(NSWorkspace.msgSend(
        bool,
        "respondsToSelector:",
        .{objc.sel("sharedWorkspace").value},
    ));
    // openURL: is an instance method.
    try std.testing.expect(NSWorkspace.msgSend(
        bool,
        "instancesRespondToSelector:",
        .{objc.sel("openURL:").value},
    ));
}

test "NSURL class resolves in ObjC runtime" {
    try std.testing.expect(objc.getClass("NSURL") != null);
}

test "NSURL responds to URLWithString:" {
    const NSURL = objc.getClass("NSURL").?;
    try std.testing.expect(NSURL.msgSend(
        bool,
        "respondsToSelector:",
        .{objc.sel("URLWithString:").value},
    ));
}

test "registerHandlers registers exactly 1 handler" {
    var bridge = try Bridge.init(
        std.testing.allocator,
        objc.Object{ .value = null },
        objc.Object{ .value = null },
    );
    defer bridge.deinit();
    try registerHandlers(&bridge);
    try std.testing.expectEqual(@as(u32, 1), bridge.dispatch.count());
    try std.testing.expect(bridge.dispatch.contains("shell.open"));
}

test "shell.open: non-string params logs and returns false (no panic)" {
    // Drive handleOpen with a non-string params value and confirm it does not
    // panic. Resolve goes to a nil webview — messaging nil is safe headlessly.
    var bridge = try Bridge.init(
        std.testing.allocator,
        objc.Object{ .value = null },
        objc.Object{ .value = null },
    );
    defer bridge.deinit();
    try registerHandlers(&bridge);

    // .null params triggers the non-string branch.
    try bridge.dispatchSlice(
        \\{"method":"shell.open","params":null,"id":1}
    );
    // .integer params likewise.
    try bridge.dispatchSlice(
        \\{"method":"shell.open","params":42,"id":2}
    );
}

test "shell.open: malformed URL string — NSURL nil guard, no panic" {
    // A URL string that NSURL URLWithString: cannot parse returns nil; the
    // handler must guard the nil and not crash. Messaging nil is safe in ObjC.
    var bridge = try Bridge.init(
        std.testing.allocator,
        objc.Object{ .value = null },
        objc.Object{ .value = null },
    );
    defer bridge.deinit();
    try registerHandlers(&bridge);

    // The empty string and a clearly invalid URL both yield nil from URLWithString:.
    try bridge.dispatchSlice(
        \\{"method":"shell.open","params":"","id":1}
    );
    try bridge.dispatchSlice(
        \\{"method":"shell.open","params":"not a url %%%","id":2}
    );
}

test "shell.open: fire-and-forget (no id) — every early-exit branch tolerates null id" {
    // Every early-return branch in handleOpen guards id with `if (id) |i|`; a
    // missing `id` field must never panic regardless of which branch is taken.
    // This covers the non-string-params branch AND the nil-NSURL branch without
    // an id, which none of the other tests exercise.
    var bridge = try Bridge.init(
        std.testing.allocator,
        objc.Object{ .value = null },
        objc.Object{ .value = null },
    );
    defer bridge.deinit();
    try registerHandlers(&bridge);

    // Non-string params, no id: the params-type guard fires with id = null.
    try bridge.dispatchSlice(
        \\{"method":"shell.open","params":null}
    );
    try bridge.dispatchSlice(
        \\{"method":"shell.open","params":{"url":"https://example.com"}}
    );

    // Nil-NSURL path, no id: URLWithString: returns nil, branch fires with id = null.
    try bridge.dispatchSlice(
        \\{"method":"shell.open","params":""}
    );
    try bridge.dispatchSlice(
        \\{"method":"shell.open","params":"not a url %%%"}
    );
}
