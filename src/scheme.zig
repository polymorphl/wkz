//! Custom `app://` URL scheme handler for embedded assets.
//!
//! Responsibility: a `WKURLSchemeHandler` that serves a compile-time
//! `AssetMap` at `app://local` in release builds — path → asset resolution,
//! MIME typing, and `WKURLSchemeTask` response/finish. Zero external assets at
//! runtime. Main thread only. No ARC.
//!
//! M4.1 scope: the scheme-handler protocol class + response/error machinery +
//! `SchemeHandler` public struct + `AssetMap`/`AssetEntry` types. No
//! `@embedFile` here — the actual file list and embeddings land in M4.2. The
//! caller constructs an `AssetMap` (comptime or stub) and passes it to
//! `SchemeHandler.init`.
//!
//! Thread safety: all AppKit/WebKit calls (including `impStart` / `impStop`)
//! must run on the main thread. WebKit guarantees it calls scheme-handler
//! methods on the main thread.

const std = @import("std");
const objc = @import("objc");

const c = objc.c;

/// Scoped logger.
const log = std.log.scoped(.wkz_scheme);

/// Process-unique name for the runtime `WKURLSchemeHandler` subclass.
const handler_class_name: [:0]const u8 = "WkzURLSchemeHandler";

/// Name of the `id`-typed instance variable that stores a borrowed
/// `*const AssetMap` pointer (see ownership notes on `SchemeHandler`).
const assets_ivar_name: [:0]const u8 = "wkz_assets";

/// NSURLErrorDomain code for "file not found". Sent via `didFailWithError:`
/// when the requested path has no entry in the `AssetMap`.
const NSURLErrorFileDoesNotExist: c_long = -1100;

// =====================================================================
// Public types
// =====================================================================

/// Errors surfaced while creating a `SchemeHandler`.
pub const Error = error{
    /// A required Foundation/WebKit class could not be looked up in the runtime.
    ClassNotFound,
};

/// One embedded asset: its raw bytes and the MIME type to serve it as.
pub const AssetEntry = struct {
    data: []const u8,
    mime: [:0]const u8,
};

/// One entry in an `AssetMap`: the URL path and the asset it maps to.
/// Declared as a named type so callers can build `[]const AssetMapEntry`
/// arrays without running into Zig's anonymous-struct type-distinctness rules.
pub const AssetMapEntry = struct {
    path: []const u8,
    asset: AssetEntry,
};

/// A comptime-constructed lookup table of URL path → `AssetEntry`.
///
/// Entries are static: `data` points into `@embedFile` output (static
/// lifetime), `mime` is a string literal. No allocator is needed to create or
/// use an `AssetMap`.
pub const AssetMap = struct {
    entries: []const AssetMapEntry,

    /// Look up `path` in the map. Returns the matching `AssetEntry` or `null`
    /// if not found. Linear scan — the map is small (a compiled bundle).
    pub fn get(self: *const AssetMap, path: []const u8) ?AssetEntry {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.path, path)) return e.asset;
        }
        return null;
    }
};

/// A live `WKURLSchemeHandler` instance wired to an `AssetMap`.
///
/// Ownership (no ARC):
///   * `handler` is a `+1` instance of the runtime `WkzURLSchemeHandler`
///     subclass, alloc/init'd by `init` and released by `deinit`.
///   * The handler's `wkz_assets` ivar holds a BORROWED `*const AssetMap`
///     pointer. It is a raw pointer stored in an `id`-typed ivar via
///     `object_setIvar` (no retain), exactly as `bridge.zig` stores `*Bridge`.
///     The `AssetMap` is NOT an Objective-C object and must never be
///     retained/released through that slot. The caller keeps the `AssetMap`
///     alive for the handler's lifetime; `deinit` does NOT release the map.
///
/// Lifetime: install BEFORE creating the WKWebView (WebKit freezes the
/// configuration after `initWithFrame:configuration:`). Use
/// `WebView.initWithSchemeHandler` which handles the ordering.
pub const SchemeHandler = struct {
    /// The owned `+1` handler instance. Released by `deinit`.
    handler: objc.Object,

    /// Create the handler class (idempotent), alloc/init an instance, and
    /// store the borrowed `assets` pointer in its ivar.
    ///
    /// `assets` is borrowed — NOT retained, NOT owned. The caller must keep
    /// the `AssetMap` alive for the lifetime of the `SchemeHandler` and the
    /// `WKWebView` that uses it.
    ///
    /// On the error path no reference is leaked (errdefer releases the `+1`
    /// handler if class lookup fails after alloc/init).
    pub fn init(assets: *const AssetMap) Error!SchemeHandler {
        const cls = try schemeHandlerClass();

        // +1 handler instance owned by this struct (released by deinit).
        const handler = cls.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "init", .{});
        errdefer handler.msgSend(void, "release", .{});

        // Raw pointer store into the id ivar: object_setIvar performs no
        // retain under MRC, so the borrowed *const AssetMap is not given
        // object semantics. This is the same pattern bridge.zig uses for
        // *Bridge. Casting away const is intentional: the ivar is `id`-typed
        // (non-const pointer), but `impStart` casts back to `*const AssetMap`.
        handler.setInstanceVariable(
            assets_ivar_name,
            .{ .value = @ptrCast(@constCast(assets)) },
        );

        return .{ .handler = handler };
    }

    /// Return the raw `objc.Object` handler for passing to
    /// `WKWebViewConfiguration setURLSchemeHandler:forURLScheme:`.
    /// The returned object is BORROWED (not an additional +1).
    pub fn object(self: SchemeHandler) objc.Object {
        return self.handler;
    }

    /// Release the owned `+1` handler instance. After this the `SchemeHandler`
    /// is dead. Must be called on the main thread.
    pub fn deinit(self: *SchemeHandler) void {
        self.handler.msgSend(void, "release", .{});
    }
};

// =====================================================================
// MIME type helper
// =====================================================================

/// Map a file path's extension to a MIME type. Falls back to
/// `application/octet-stream` for unknown extensions. Pure Zig, no ObjC.
pub fn mimeForPath(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".ico")) return "image/x-icon";
    if (std.mem.endsWith(u8, path, ".woff2")) return "font/woff2";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json";
    return "application/octet-stream";
}

// =====================================================================
// ObjC class creation (idempotent, process-lived)
// =====================================================================

/// Create (or look up) the runtime `WKURLSchemeHandler` subclass.
///
/// Idempotent: a registered ObjC class lives for the process and is not
/// reference-counted. Calling this twice returns the same class.
fn schemeHandlerClass() Error!objc.Class {
    if (objc.getClass(handler_class_name)) |existing| return existing;

    const NSObject = objc.getClass("NSObject") orelse return Error.ClassNotFound;

    const cls = objc.allocateClassPair(NSObject, handler_class_name) orelse
        return Error.ClassNotFound;

    // Ivars must be added before registerClassPair.
    std.debug.assert(cls.addIvar(assets_ivar_name));

    // Both WKURLSchemeHandler protocol methods.
    std.debug.assert(cls.addMethod("webView:startURLSchemeTask:", impStart));
    std.debug.assert(cls.addMethod("webView:stopURLSchemeTask:", impStop));

    objc.registerClassPair(cls);
    return cls;
}

// =====================================================================
// IMPs
// =====================================================================

/// IMP for `-[WkzURLSchemeHandler webView:startURLSchemeTask:]`.
///
/// C-ABI convention: first two params are `c.id self` / `c.SEL _cmd`, then
/// the two selector arguments (webview id, task id). zig-objc derives the
/// encoding `v@:@@` from this signature.
///
/// Flow:
///   1. Recover `*const AssetMap` from the handler ivar.
///   2. Get the request URL path from the task.
///   3. Strip the leading `/` and look up in the map.
///   4a. Found → build `NSHTTPURLResponse` + `NSData`, call
///       `didReceiveResponse:` + `didReceiveData:` + `didFinish`.
///   4b. Not found → call `didFailWithError:` with NSURLErrorDomain/-1100.
///
/// ARC ownership of transient ObjC objects created in this IMP:
///   * `ns_mime`      — `+1` (stringWithUTF8String: + retain). Released via defer.
///   * `http_version` — `+1` (stringWithUTF8String: + retain). Released via defer.
///   * `content_type_key` — `+1`. Released via defer.
///   * `headers`      — `+1` (dictionaryWithObject:forKey: returns autoreleased;
///                       we retain immediately to get a deterministic +1). Released via defer.
///   * `ns_response`  — `+1` (alloc/init). Released via defer.
///   * `ns_data`      — `+1` (dataWithBytesNoCopy:length:freeWhenDone: returns
///                       autoreleased; we retain for a deterministic +1). Released via defer.
///   * `ns_url_error_domain` — `+1`. Released via defer (error path only).
///   * `ns_error`     — `+1` (errorWithDomain:code:userInfo: returns autoreleased;
///                       retained for +1). Released via defer (error path only).
fn impStart(
    self: c.id,
    _cmd: c.SEL,
    webview: c.id,
    task: c.id,
) callconv(.c) void {
    _ = _cmd;
    _ = webview;

    const handler = objc.Object{ .value = self };
    const task_obj = objc.Object{ .value = task };

    // Recover the borrowed *const AssetMap from the ivar. Raw pointer read,
    // no retain — the inverse of the raw store in SchemeHandler.init.
    const ctx = handler.getInstanceVariable(assets_ivar_name);
    if (ctx.value == null) {
        log.warn("scheme handler: no asset map attached; dropping task", .{});
        return;
    }
    const assets: *const AssetMap = @ptrCast(@alignCast(ctx.value));

    // Look up Foundation / WebKit classes. If any are missing, the framework
    // is gone — nothing safe to do.
    const NSString = objc.getClass("NSString") orelse {
        log.warn("scheme handler: NSString class not found", .{});
        return;
    };
    const NSData = objc.getClass("NSData") orelse {
        log.warn("scheme handler: NSData class not found", .{});
        return;
    };
    const NSDictionary = objc.getClass("NSDictionary") orelse {
        log.warn("scheme handler: NSDictionary class not found", .{});
        return;
    };
    const NSHTTPURLResponse = objc.getClass("NSHTTPURLResponse") orelse {
        log.warn("scheme handler: NSHTTPURLResponse class not found", .{});
        return;
    };

    // Extract the task URL path.
    //   -[WKURLSchemeTask request]  -> NSURLRequest (borrowed, autoreleased)
    //   -[NSURLRequest URL]         -> NSURL (borrowed, autoreleased)
    //   -[NSURL path]               -> NSString (borrowed, autoreleased)
    //   -[NSString UTF8String]      -> const char * (borrowed, null if non-UTF8)
    //
    // The task URL is also needed as an NSURL object for NSHTTPURLResponse.
    const request = task_obj.msgSend(objc.Object, "request", .{});
    const url_obj = request.msgSend(objc.Object, "URL", .{});
    const path_nsstr = url_obj.msgSend(objc.Object, "path", .{});
    const path_cstr = path_nsstr.msgSend(?[*:0]const u8, "UTF8String", .{});
    if (path_cstr == null) {
        log.warn("scheme handler: non-UTF8 or missing URL path; dropping with 404", .{});
    }
    const raw_path: []const u8 = if (path_cstr) |p| std.mem.span(p) else "";

    // Strip the mandatory leading `/` that WebKit always prepends to the path
    // component. "app://local/index.html" → path = "/index.html" → "index.html".
    const path: []const u8 = if (raw_path.len > 0 and raw_path[0] == '/') raw_path[1..] else raw_path;

    if (assets.get(path)) |entry| {
        // --- 200 OK path ---

        // +1 NSString for the MIME type. Caller (us) owns; defer releases.
        const ns_mime = nsString(NSString, entry.mime);
        defer ns_mime.msgSend(void, "release", .{});

        // +1 NSString for the HTTP version header.
        const http_version = nsString(NSString, "HTTP/1.1");
        defer http_version.msgSend(void, "release", .{});

        // +1 NSString for the header key "Content-Type".
        const content_type_key = nsString(NSString, "Content-Type");
        defer content_type_key.msgSend(void, "release", .{});

        // +1 NSDictionary for headerFields: @{@"Content-Type": mime}.
        // +[NSDictionary dictionaryWithObject:forKey:] is a factory convenience
        // method → autoreleased. We retain immediately for a deterministic +1.
        const headers_ar = NSDictionary.msgSend(
            objc.Object,
            "dictionaryWithObject:forKey:",
            .{ ns_mime, content_type_key },
        );
        const headers = headers_ar.msgSend(objc.Object, "retain", .{});
        defer headers.msgSend(void, "release", .{});

        // +1 NSHTTPURLResponse via alloc/initWithURL:statusCode:HTTPVersion:headerFields:
        // Verified against Apple docs: statusCode is NSInteger (c_long on arm64).
        const ns_response = NSHTTPURLResponse.msgSend(objc.Object, "alloc", .{})
            .msgSend(
            objc.Object,
            "initWithURL:statusCode:HTTPVersion:headerFields:",
            .{ url_obj, @as(c_long, 200), http_version, headers },
        );
        defer ns_response.msgSend(void, "release", .{});

        // +1 NSData: +[NSData dataWithBytesNoCopy:length:freeWhenDone:NO].
        // The embedded bytes have static lifetime; freeWhenDone:NO means NSData
        // does NOT call free() on them — correct for @embedFile'd / static data.
        // This factory returns an autoreleased object; we retain for +1.
        // length is NSUInteger (c_ulong on arm64).
        const ns_data_ar = NSData.msgSend(
            objc.Object,
            "dataWithBytesNoCopy:length:freeWhenDone:",
            .{
                @as(?*anyopaque, @ptrCast(@constCast(entry.data.ptr))),
                @as(c_ulong, entry.data.len),
                @as(bool, false),
            },
        );
        const ns_data = ns_data_ar.msgSend(objc.Object, "retain", .{});
        defer ns_data.msgSend(void, "release", .{});

        // Deliver the response to WebKit.
        task_obj.msgSend(void, "didReceiveResponse:", .{ns_response});
        task_obj.msgSend(void, "didReceiveData:", .{ns_data});
        task_obj.msgSend(void, "didFinish", .{});
    } else {
        // --- 404 / not-found path ---
        log.warn("scheme handler: asset not found: {s}", .{path});

        const NSError = objc.getClass("NSError") orelse {
            log.warn("scheme handler: NSError class not found", .{});
            return;
        };

        // +1 NSString for the error domain.
        const ns_url_error_domain = nsString(NSString, "NSURLErrorDomain");
        defer ns_url_error_domain.msgSend(void, "release", .{});

        // +[NSError errorWithDomain:code:userInfo:] → autoreleased; retain for +1.
        // code is NSInteger (c_long). userInfo is nil.
        const ns_error_ar = NSError.msgSend(
            objc.Object,
            "errorWithDomain:code:userInfo:",
            .{
                ns_url_error_domain,
                @as(c_long, NSURLErrorFileDoesNotExist),
                @as(?*anyopaque, null),
            },
        );
        const ns_error = ns_error_ar.msgSend(objc.Object, "retain", .{});
        defer ns_error.msgSend(void, "release", .{});

        task_obj.msgSend(void, "didFailWithError:", .{ns_error});
    }
}

/// IMP for `-[WkzURLSchemeHandler webView:stopURLSchemeTask:]`.
///
/// Called when WebKit cancels a task (e.g. the page navigated away). Since
/// `impStart` responds synchronously (it calls `didReceiveResponse:` +
/// `didReceiveData:` + `didFinish` or `didFailWithError:` before returning),
/// there is no outstanding async work to cancel — this is intentionally a
/// no-op. Encoding `v@:@@` derived by zig-objc.
fn impStop(
    self: c.id,
    _cmd: c.SEL,
    webview: c.id,
    task: c.id,
) callconv(.c) void {
    _ = self;
    _ = _cmd;
    _ = webview;
    _ = task;
    // Synchronous handler: nothing to cancel.
}

// =====================================================================
// Internal helpers
// =====================================================================

/// Returns a `+1` NSString built from a NUL-terminated UTF-8 sentinel slice.
/// Caller owns it and must `release` it. `-[NSString stringWithUTF8String:]`
/// returns an autoreleased string; we `retain` it for a deterministic `+1`
/// reference the caller releases explicitly. Same pattern as `bridge.zig`.
fn nsString(NSString: objc.Class, str: [:0]const u8) objc.Object {
    const s = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{str.ptr});
    return s.msgSend(objc.Object, "retain", .{});
}

// =====================================================================
// Tests
// =====================================================================

test "mimeForPath: all documented extensions return the correct MIME type" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", mimeForPath("index.html"));
    try std.testing.expectEqualStrings("text/html; charset=utf-8", mimeForPath("/foo/bar.html"));
    try std.testing.expectEqualStrings("application/javascript; charset=utf-8", mimeForPath("app.js"));
    try std.testing.expectEqualStrings("application/javascript; charset=utf-8", mimeForPath("assets/index-abc123.js"));
    try std.testing.expectEqualStrings("text/css; charset=utf-8", mimeForPath("style.css"));
    try std.testing.expectEqualStrings("image/svg+xml", mimeForPath("logo.svg"));
    try std.testing.expectEqualStrings("image/png", mimeForPath("icon.png"));
    try std.testing.expectEqualStrings("image/x-icon", mimeForPath("favicon.ico"));
    try std.testing.expectEqualStrings("font/woff2", mimeForPath("font.woff2"));
    try std.testing.expectEqualStrings("application/json", mimeForPath("data.json"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeForPath("binary.wasm"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeForPath("unknown"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeForPath(""));
}

test "schemeHandlerClass: creates and registers the class" {
    const cls = try schemeHandlerClass();
    try std.testing.expect(objc.getClass(handler_class_name) != null);
    try std.testing.expectEqual(objc.getClass(handler_class_name).?.value, cls.value);
}

test "schemeHandlerClass: idempotent (returns same class on repeated calls)" {
    const a = try schemeHandlerClass();
    const b = try schemeHandlerClass();
    try std.testing.expectEqual(a.value, b.value);
}

test "handler instances respond to WKURLSchemeHandler selectors" {
    const cls = try schemeHandlerClass();
    // instancesRespondToSelector: verifies the selectors were registered.
    try std.testing.expect(cls.msgSend(
        bool,
        "instancesRespondToSelector:",
        .{objc.sel("webView:startURLSchemeTask:").value},
    ));
    try std.testing.expect(cls.msgSend(
        bool,
        "instancesRespondToSelector:",
        .{objc.sel("webView:stopURLSchemeTask:").value},
    ));
}

test "handler instances do NOT respond to an unregistered selector (negative control)" {
    const cls = try schemeHandlerClass();
    try std.testing.expect(!cls.msgSend(
        bool,
        "instancesRespondToSelector:",
        .{objc.sel("wkzNeverRegisteredOnSchemeHandler:").value},
    ));
}

test "ivar round-trip: *const AssetMap stored and recovered" {
    const cls = try schemeHandlerClass();
    const inst = cls.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer inst.msgSend(void, "release", .{});

    // Build a minimal AssetMap on the stack.
    const entries = [_]AssetMapEntry{
        .{ .path = "index.html", .asset = .{ .data = "<h1>hi</h1>", .mime = "text/html; charset=utf-8" } },
    };
    const map = AssetMap{ .entries = &entries };

    // Store (same raw-pointer-in-id pattern as SchemeHandler.init).
    inst.setInstanceVariable(
        assets_ivar_name,
        .{ .value = @ptrCast(@constCast(&map)) },
    );

    // Recover and verify pointer identity.
    const got = inst.getInstanceVariable(assets_ivar_name);
    try std.testing.expect(got.value != null);
    const recovered: *const AssetMap = @ptrCast(@alignCast(got.value));
    try std.testing.expectEqual(&map, recovered);
}

test "AssetMap.get: found, not-found, and leading-slash stripped by caller convention" {
    const entries = [_]AssetMapEntry{
        .{ .path = "index.html", .asset = .{ .data = "hello", .mime = "text/html; charset=utf-8" } },
        .{ .path = "assets/app.js", .asset = .{ .data = "js", .mime = "application/javascript; charset=utf-8" } },
    };
    const map = AssetMap{ .entries = &entries };

    // Found — direct path match.
    const a = map.get("index.html");
    try std.testing.expect(a != null);
    try std.testing.expectEqualStrings("hello", a.?.data);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", a.?.mime);

    // Found — nested path.
    const b = map.get("assets/app.js");
    try std.testing.expect(b != null);
    try std.testing.expectEqualStrings("js", b.?.data);

    // Not found.
    try std.testing.expect(map.get("missing.txt") == null);
    try std.testing.expect(map.get("") == null);

    // Leading-slash stripping is the IMP caller's job (impStart strips `/`
    // from the NSURL path component before calling map.get). Verify that
    // map.get does NOT strip the slash itself — "/index.html" ≠ "index.html".
    try std.testing.expect(map.get("/index.html") == null);
}

test "SchemeHandler.init creates an instance; .deinit releases it" {
    const entries = [_]AssetMapEntry{};
    const map = AssetMap{ .entries = &entries };

    var sh = try SchemeHandler.init(&map);
    // handler must be a non-null instance of WkzURLSchemeHandler.
    try std.testing.expect(sh.handler.value != null);
    try std.testing.expect(sh.handler.msgSend(
        bool,
        "isKindOfClass:",
        .{objc.getClass(handler_class_name).?},
    ));

    // object() returns the same underlying pointer (borrowed, not +1).
    try std.testing.expectEqual(sh.handler.value, sh.object().value);

    // The ivar was written: recover the pointer and compare.
    const ctx = sh.handler.getInstanceVariable(assets_ivar_name);
    try std.testing.expect(ctx.value != null);
    const recovered: *const AssetMap = @ptrCast(@alignCast(ctx.value));
    try std.testing.expectEqual(&map, recovered);

    sh.deinit();
    // After deinit the struct is dead; no further use here.
}

test "WKWebViewConfiguration responds to setURLSchemeHandler:forURLScheme: (headless class check)" {
    // Verifies that the WebKit class exposes the selector we will use in
    // WebView.initWithSchemeHandler. Pure class-metadata query — no window
    // server, no allocation of a real view.
    const WKWebViewConfiguration = objc.getClass("WKWebViewConfiguration") orelse
        return error.SkipZigTest;
    try std.testing.expect(WKWebViewConfiguration.msgSend(
        bool,
        "instancesRespondToSelector:",
        .{objc.sel("setURLSchemeHandler:forURLScheme:").value},
    ));
}

test "NSHTTPURLResponse and NSData classes resolve and respond to used selectors" {
    // Headless runtime-presence check. If these selectors are wrong, the IMP
    // would silently no-op in production; catching them here is cheaper.
    const NSHTTPURLResponse = objc.getClass("NSHTTPURLResponse") orelse
        return error.SkipZigTest;
    try std.testing.expect(NSHTTPURLResponse.msgSend(
        bool,
        "instancesRespondToSelector:",
        .{objc.sel("initWithURL:statusCode:HTTPVersion:headerFields:").value},
    ));

    const NSData = objc.getClass("NSData") orelse return error.SkipZigTest;
    try std.testing.expect(NSData.msgSend(
        bool,
        "respondsToSelector:",
        .{objc.sel("dataWithBytesNoCopy:length:freeWhenDone:").value},
    ));

    const NSError = objc.getClass("NSError") orelse return error.SkipZigTest;
    try std.testing.expect(NSError.msgSend(
        bool,
        "respondsToSelector:",
        .{objc.sel("errorWithDomain:code:userInfo:").value},
    ));
}

test "AssetEntry.mime is [:0]const u8 (compile-time sentinel-slice pin)" {
    // Compile-time type assertion: if `mime` changes from [:0]const u8 to
    // []const u8 (dropping the NUL sentinel), the `nsString` helper in impStart
    // which calls `.ptr` on the slice would silently compile but could produce a
    // non-NUL-terminated string. This pin catches that at compile time rather
    // than at runtime crash in impStart.
    const mime_type = @FieldType(AssetEntry, "mime");
    comptime {
        // Verify it is a pointer type with a sentinel.
        const info = @typeInfo(mime_type);
        if (info != .pointer) @compileError("AssetEntry.mime must be a pointer type");
        if (info.pointer.sentinel_ptr == null) @compileError("AssetEntry.mime must be a sentinel slice [:0]const u8");
        if (info.pointer.child != u8) @compileError("AssetEntry.mime child must be u8");
        if (!info.pointer.is_const) @compileError("AssetEntry.mime must be const");
    }
    // Confirm at runtime too: a string literal assigned to mime is NUL-terminated.
    const entry = AssetEntry{ .data = "hello", .mime = "text/html; charset=utf-8" };
    try std.testing.expectEqual(@as(u8, 0), entry.mime[entry.mime.len]);
}

test "AssetMap.get returns null for every unknown path (not-found contract)" {
    // Distinct from the slash-stripping test: this exercises the null return for
    // paths that are simply absent from the map, covering: a plausible path
    // (wrong extension), an empty string, an extension-only string, a path with
    // a Unicode suffix, and a path that is a prefix or suffix of an existing key.
    const entries = [_]AssetMapEntry{
        .{ .path = "index.html", .asset = .{ .data = "body", .mime = "text/html; charset=utf-8" } },
    };
    const map = AssetMap{ .entries = &entries };

    try std.testing.expect(map.get("index.htm") == null); // prefix of known ext
    try std.testing.expect(map.get("index.html.gz") == null); // suffix beyond known
    try std.testing.expect(map.get("") == null); // empty
    try std.testing.expect(map.get(".html") == null); // extension only
    try std.testing.expect(map.get("INDEX.HTML") == null); // case-sensitive
    try std.testing.expect(map.get("index.html\x00") == null); // embedded NUL
    try std.testing.expect(map.get("index.html ") == null); // trailing space
}

test {
    std.testing.refAllDecls(@This());
}
