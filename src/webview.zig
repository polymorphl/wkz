//! WKWebView creation, configuration, and content loading.
//!
//! Responsibility: build a WKWebView (with a WKWebViewConfiguration), add it as
//! a subview of an existing window's contentView sized to fill it (and to keep
//! filling on resize), enable the Web Inspector (`inspectable = true`), and load
//! content — `loadHTMLString:baseURL:` for inline HTML here; loadRequest (dev)
//! and the app:// scheme (prod) land later. Main thread only; release paired in
//! `deinit`. No ARC.

const std = @import("std");
const objc = @import("objc");
const win = @import("window.zig");

/// Core Graphics geometry, shared from window.zig so there is one canonical
/// CGRect/CGFloat ABI across the project rather than a duplicate definition.
const CGFloat = win.CGFloat;
const CGRect = win.CGRect;

/// `NSAutoresizingMaskOptions` flag values (AppKit/NSView.h). Stable since 10.0.
/// `Width|HeightSizable` makes the webview grow/shrink with its superview so it
/// keeps filling the contentView when the window is resized.
const NSViewWidthSizable: c_ulong = 1 << 1; // 2
const NSViewHeightSizable: c_ulong = 1 << 4; // 16

/// `CGRect`/`NSRect` of zero origin and size. The initial frame is irrelevant:
/// `attach` overwrites it with the contentView's bounds before display.
const CGRectZero: CGRect = .{
    .origin = .{ .x = 0, .y = 0 },
    .size = .{ .width = 0, .height = 0 },
};

/// Errors surfaced while creating a webview.
pub const Error = error{
    /// A required WebKit/Foundation class could not be looked up in the runtime.
    /// This only happens if WebKit failed to link/load, which is fatal.
    ClassNotFound,
};

/// A WKWebView attached to (and filling) a window's contentView.
///
/// Ownership: `init` produces a `+1` WKWebView reference (alloc/init) that this
/// struct owns; `deinit` releases it. The transient WKWebViewConfiguration is
/// also `+1` from alloc/init — `initWithFrame:configuration:` makes WKWebView
/// retain it, so `init` releases its own configuration reference before
/// returning, leaving exactly one owned reference (the webview). Adding the
/// webview as a subview makes the superview retain it too, so the webview
/// survives until both that retain is dropped (on view/window teardown) and our
/// `deinit` release runs. No ARC: the single owning reference is balanced by the
/// one `release` in `deinit`.
pub const WebView = struct {
    /// The owned `WKWebView` (`+1`). Released by `deinit`.
    ns_webview: objc.Object,

    /// Create a WKWebView with a fresh WKWebViewConfiguration and enable the
    /// Web Inspector. The webview is not attached to any window yet — call
    /// `attach` to add it to a window's contentView.
    ///
    /// Must be called on the main thread. On success the returned `WebView` owns
    /// a `+1` WKWebView reference that `deinit` releases. On the error path no
    /// reference is leaked.
    pub fn init() Error!WebView {
        const WKWebView = objc.getClass("WKWebView") orelse return Error.ClassNotFound;
        const WKWebViewConfiguration = objc.getClass("WKWebViewConfiguration") orelse
            return Error.ClassNotFound;

        // +1 configuration; consumed (retained) by initWithFrame:configuration:.
        // We release our own reference once the webview holds its own.
        const config = WKWebViewConfiguration.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "init", .{});
        defer config.msgSend(void, "release", .{});

        // alloc/init -> +1 reference owned by this struct (released in deinit).
        // CGRectZero is fine: attach() resizes to the contentView bounds.
        const ns_webview = WKWebView.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithFrame:configuration:", .{ CGRectZero, config });
        errdefer ns_webview.msgSend(void, "release", .{});

        // Enable the Web Inspector (macOS 13.3+). setInspectable: takes a BOOL.
        ns_webview.msgSend(void, "setInspectable:", .{@as(bool, true)});

        return .{ .ns_webview = ns_webview };
    }

    /// Add the webview to `window`'s contentView, sized to fill it and set to
    /// keep filling on resize (width|height autoresizing). The contentView
    /// retains the webview when it is added; we still own our `+1` reference
    /// (released in `deinit`). Must be called on the main thread.
    ///
    /// The `window` argument is not consumed — the caller retains ownership and
    /// must keep the `Window` alive for as long as the webview is attached.
    pub fn attach(self: WebView, window: win.Window) void {
        const content_view = window.contentView();

        // Match the webview's frame to the contentView's current bounds, then
        // let the autoresizing mask keep it filling as the window resizes.
        const bounds: CGRect = content_view.msgSend(CGRect, "bounds", .{});
        self.ns_webview.msgSend(void, "setFrame:", .{bounds});
        self.ns_webview.msgSend(
            void,
            "setAutoresizingMask:",
            .{NSViewWidthSizable | NSViewHeightSizable},
        );

        // contentView retains the webview as a subview.
        content_view.msgSend(void, "addSubview:", .{self.ns_webview});
    }

    /// The webview's `WKUserContentController` — the object script message
    /// handlers are registered on (see `bridge.zig`). Reached via
    /// `-[WKWebView configuration]` → `-[WKWebViewConfiguration userContentController]`.
    ///
    /// `-[WKWebView configuration]` returns a *copy* of the configuration, but
    /// that copy keeps a strong reference to the same `WKUserContentController`
    /// instance the live webview routes messages through — so a handler added to
    /// the returned controller takes effect for this webview. The returned
    /// reference is owned by the configuration/webview, not the caller: do NOT
    /// release it. Must be called on the main thread.
    ///
    /// Note: pointer identity with the live routing controller was verified in a
    /// headless test (webview.zig tests), but live message routing through this
    /// controller has only been confirmed manually (see checklist M2.2-G2).
    ///
    /// Ordering note: a handler must be installed BEFORE content that posts to it
    /// is loaded — `addScriptMessageHandler:name:` only affects content loaded
    /// after the call. Install via `bridge.zig` before `loadHTMLString`.
    pub fn userContentController(self: WebView) objc.Object {
        const config = self.ns_webview.msgSend(objc.Object, "configuration", .{});
        return config.msgSend(objc.Object, "userContentController", .{});
    }

    /// Create a WKWebView with a custom URL scheme handler pre-registered on
    /// its configuration. The scheme handler MUST be registered before the
    /// WKWebView is created — `WKWebViewConfiguration` is frozen afterwards.
    ///
    /// `handler` is borrowed (not +1, not retained by this function). Pass
    /// `SchemeHandler.object()` from a live `SchemeHandler`.
    /// `scheme` is a NUL-terminated scheme string (e.g. `"app"`).
    ///
    /// Ownership is identical to `init()`: `deinit` releases the `+1`
    /// WKWebView; the transient config `+1` is released once the webview holds
    /// its own reference. On the error path no reference is leaked.
    ///
    /// Must be called on the main thread.
    pub fn initWithSchemeHandler(handler: objc.Object, scheme: [:0]const u8) Error!WebView {
        const WKWebView = objc.getClass("WKWebView") orelse return Error.ClassNotFound;
        const WKWebViewConfiguration = objc.getClass("WKWebViewConfiguration") orelse
            return Error.ClassNotFound;
        const NSString = objc.getClass("NSString") orelse return Error.ClassNotFound;

        // +1 configuration; released once the webview retains it.
        const config = WKWebViewConfiguration.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "init", .{});
        defer config.msgSend(void, "release", .{});

        // Register the scheme handler BEFORE initWithFrame:configuration:.
        // WebKit freezes the configuration after the webview is created.
        // +1 NSString for the scheme; released after the registration call.
        const ns_scheme = nsString(NSString, scheme);
        defer ns_scheme.msgSend(void, "release", .{});
        config.msgSend(void, "setURLSchemeHandler:forURLScheme:", .{ handler, ns_scheme });

        // alloc/init -> +1 WKWebView owned by this struct (released in deinit).
        const ns_webview = WKWebView.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithFrame:configuration:", .{ CGRectZero, config });
        errdefer ns_webview.msgSend(void, "release", .{});

        ns_webview.msgSend(void, "setInspectable:", .{@as(bool, true)});

        return .{ .ns_webview = ns_webview };
    }

    /// Load a URL via `-[WKWebView loadRequest:]` with an `NSURLRequest` built
    /// from `url` (a NUL-terminated UTF-8 string, e.g. `"http://localhost:5173"`).
    ///
    /// Ownership:
    /// - `NSString` from `nsString()`: `+1` (stringWithUTF8String: + retain).
    ///   Released via `defer` before this function returns.
    /// - `NSURL` from `+[NSURL URLWithString:]`: **autoreleased** (`+0` from our
    ///   perspective — we did not alloc/new/copy/retain it). Do NOT release it.
    /// - `NSURLRequest` from `+[NSURLRequest requestWithURL:]`: **autoreleased**
    ///   (`+0`). Do NOT release it.
    ///
    /// Must be called on the main thread.
    pub fn loadURL(self: WebView, url: [:0]const u8) Error!void {
        const NSString = objc.getClass("NSString") orelse return Error.ClassNotFound;
        const NSURL = objc.getClass("NSURL") orelse return Error.ClassNotFound;
        const NSURLRequest = objc.getClass("NSURLRequest") orelse return Error.ClassNotFound;

        // +1 NSString; we own this and release it before returning.
        const ns_url_str = nsString(NSString, url);
        defer ns_url_str.msgSend(void, "release", .{});

        // Autoreleased (+0): factory convenience method, not alloc/new/copy/retain.
        // WKWebView retains the request internally; we must NOT release it.
        const nsurl = NSURL.msgSend(objc.Object, "URLWithString:", .{ns_url_str});
        const request = NSURLRequest.msgSend(objc.Object, "requestWithURL:", .{nsurl});

        self.ns_webview.msgSend(void, "loadRequest:", .{request});
    }

    /// Load an inline HTML page via `-[WKWebView loadHTMLString:baseURL:]`.
    /// `base_url` is passed as nil (no relative-URL resolution base), which is
    /// fine for self-contained HTML. The HTML NSString is built transiently and
    /// released after the load is requested (WKWebView copies what it needs).
    /// Must be called on the main thread.
    pub fn loadHTMLString(self: WebView, html: [:0]const u8) Error!void {
        const NSString = objc.getClass("NSString") orelse return Error.ClassNotFound;
        const ns_html = nsString(NSString, html);
        defer ns_html.msgSend(void, "release", .{});
        self.ns_webview.msgSend(
            void,
            "loadHTMLString:baseURL:",
            .{ ns_html, @as(?*anyopaque, null) },
        );
    }

    /// Release the owned WKWebView reference. After this the `WebView` is dead.
    /// Must be called on the main thread.
    pub fn deinit(self: WebView) void {
        self.ns_webview.msgSend(void, "release", .{});
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

// --- Compile-time constant / layout contracts (no WebKit calls) ---

test "autoresizing mask constants match AppKit" {
    try std.testing.expectEqual(@as(c_ulong, 2), NSViewWidthSizable);
    try std.testing.expectEqual(@as(c_ulong, 16), NSViewHeightSizable);
}

test "CGRect shared from window.zig has the expected ABI layout" {
    // webview.zig passes CGRect by value (initWithFrame:/setFrame:) and reads it
    // back (bounds/frame). Re-asserting the shared type's layout guards against a
    // future edit to window.zig silently breaking the webview ABI.
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(CGRect));
    try std.testing.expectEqual(f64, CGFloat);
    try std.testing.expectEqual(
        std.builtin.Type.ContainerLayout.@"extern",
        @typeInfo(CGRect).@"struct".layout,
    );
}

// --- API-surface / type contract (compile-time) ---

test "WebView exposes the documented public API surface" {
    try std.testing.expect(@hasField(WebView, "ns_webview"));
    try std.testing.expectEqual(objc.Object, @FieldType(WebView, "ns_webview"));

    const InitRet = @typeInfo(@TypeOf(WebView.init)).@"fn".return_type.?;
    try std.testing.expectEqual(Error!WebView, InitRet);

    try std.testing.expectEqual(void, @typeInfo(@TypeOf(WebView.attach)).@"fn".return_type.?);

    // userContentController() exposes the WKUserContentController the bridge
    // registers script message handlers on (M2.2).
    try std.testing.expectEqual(
        objc.Object,
        @typeInfo(@TypeOf(WebView.userContentController)).@"fn".return_type.?,
    );

    const LoadRet = @typeInfo(@TypeOf(WebView.loadHTMLString)).@"fn".return_type.?;
    try std.testing.expectEqual(Error!void, LoadRet);

    // loadURL: added in M3.4.  @hasDecl proves it is on the type at compile
    // time; the return-type pin below keeps the Error!void contract visible here
    // as well as in the dedicated loadURL test.
    try std.testing.expect(@hasDecl(WebView, "loadURL"));
    const LoadURLRet = @typeInfo(@TypeOf(WebView.loadURL)).@"fn".return_type.?;
    try std.testing.expectEqual(Error!void, LoadURLRet);
    // Parameter 1 (index 1, after self) must be [:0]const u8 — a NUL-terminated
    // UTF-8 string.  If this changes, main.zig string literals would silently
    // become incompatible.
    const load_url_params = @typeInfo(@TypeOf(WebView.loadURL)).@"fn".params;
    try std.testing.expectEqual([:0]const u8, load_url_params[1].type.?);

    try std.testing.expectEqual(void, @typeInfo(@TypeOf(WebView.deinit)).@"fn".return_type.?);

    // initWithSchemeHandler: added in M4.1. Pin its return type and its
    // `scheme` parameter type — a NUL-terminated sentinel slice that gets
    // passed to NSString stringWithUTF8String:. If either changes, the
    // scheme handler wiring in root.zig/main.zig must be updated in sync.
    try std.testing.expect(@hasDecl(WebView, "initWithSchemeHandler"));
    const InitSchemeRet = @typeInfo(@TypeOf(WebView.initWithSchemeHandler)).@"fn".return_type.?;
    try std.testing.expectEqual(Error!WebView, InitSchemeRet);
    // params: [0]=handler: objc.Object, [1]=scheme: [:0]const u8
    const scheme_params = @typeInfo(@TypeOf(WebView.initWithSchemeHandler)).@"fn".params;
    try std.testing.expectEqual(objc.Object, scheme_params[0].type.?);
    try std.testing.expectEqual([:0]const u8, scheme_params[1].type.?);
}

test "Error set is exactly {ClassNotFound}" {
    const fields = @typeInfo(Error).error_set.?;
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("ClassNotFound", fields[0].name);
}

test "required WebKit/Foundation classes resolve in the runtime" {
    // Pure runtime lookups — no window-server connection, safe headless.
    try std.testing.expect(objc.getClass("WKWebView") != null);
    try std.testing.expect(objc.getClass("WKWebViewConfiguration") != null);
    try std.testing.expect(objc.getClass("NSString") != null);
}

test "WKWebView/WKWebViewConfiguration respond to the selectors used" {
    // Query loaded class metadata for the instance methods init()/attach()/
    // loadHTMLString() send. Pure runtime lookups against the class objects —
    // they allocate no view and open no window-server connection, so they are
    // headless-safe. A typo in a selector string would otherwise only surface as
    // a silent no-op or crash on a real view.
    const WKWebView = objc.getClass("WKWebView").?;
    const wk_selectors = [_][:0]const u8{
        "initWithFrame:configuration:",
        "setInspectable:",
        "setFrame:",
        "setAutoresizingMask:",
        "loadHTMLString:baseURL:",
        // attach() sends addSubview: to the contentView with the webview as the
        // argument; WKWebView (an NSView subclass) also responds to bounds, which
        // attach() reads off the contentView. Asserting WKWebView responds to both
        // documents the NSView surface attach() relies on without needing a window.
        "addSubview:",
        "bounds",
        "release",
        // userContentController() reaches the WKUserContentController through the
        // webview's configuration; assert both legs resolve.
        "configuration",
    };
    inline for (wk_selectors) |name| {
        try std.testing.expect(WKWebView.msgSend(
            bool,
            "instancesRespondToSelector:",
            .{objc.sel(name).value},
        ));
    }

    const WKWebViewConfiguration = objc.getClass("WKWebViewConfiguration").?;
    try std.testing.expect(WKWebViewConfiguration.msgSend(
        bool,
        "instancesRespondToSelector:",
        .{objc.sel("init").value},
    ));
}

// --- Live instantiation (empirically headless-safe: WKWebViewConfiguration
//     alloc/init, WKWebView initWithFrame:configuration:, setInspectable:, and
//     the frame CGRect-by-value return all complete without a window server;
//     probed before writing this test) ---

test "init() builds a live WKWebView and deinit() releases it" {
    // WKWebViewConfiguration alloc/init and WKWebView initWithFrame:configuration:
    // were verified to run headless (no window server) before adding this. We do
    // NOT call attach() here: it needs a real window's contentView (NSWindow
    // creation is not headless-safe — see window.zig and the manual checklist).
    const wv = WebView.init() catch |e| {
        std.debug.print("WebView.init() failed: {s}\n", .{@errorName(e)});
        return e;
    };
    defer wv.deinit();

    try std.testing.expect(wv.ns_webview.value != null);

    // The handle is a genuine WKWebView instance.
    try std.testing.expect(wv.ns_webview.msgSend(
        bool,
        "isKindOfClass:",
        .{objc.getClass("WKWebView").?},
    ));

    // setInspectable:(true) ran in init(); read it back via -[isInspectable].
    try std.testing.expect(wv.ns_webview.msgSend(bool, "isInspectable", .{}));

    // The frame CGRect getter returns by value (arm64 plain objc_msgSend); the
    // CGRectZero frame from init() must round-trip as zero.
    const frame: CGRect = wv.ns_webview.msgSend(CGRect, "frame", .{});
    try std.testing.expectEqual(@as(CGFloat, 0), frame.size.width);
    try std.testing.expectEqual(@as(CGFloat, 0), frame.size.height);
}

test "userContentController() returns a live WKUserContentController" {
    // The bridge (M2.2) installs its script message handler on this controller.
    // configuration/userContentController traversal is headless-safe (no window
    // server) — verified alongside the other WKWebView init plumbing.
    const wv = try WebView.init();
    defer wv.deinit();

    const ucc = wv.userContentController();
    try std.testing.expect(ucc.value != null);
    try std.testing.expect(ucc.msgSend(
        bool,
        "isKindOfClass:",
        .{objc.getClass("WKUserContentController").?},
    ));
}

test "userContentController() returns a stable, identical controller across calls" {
    // Load-bearing precondition for the bridge (M2.2): a handler added via the
    // accessor must fire on the live webview. That requires the accessor to
    // return the SAME WKUserContentController instance every time — not a fresh
    // throwaway. -[WKWebView configuration] returns a *copy* of the
    // configuration, so the open question the reviewer flagged is whether the
    // copy's userContentController is a stable instance. Here we PROVE pointer
    // identity that is headlessly observable:
    //
    //   (a) Two calls to the accessor return the exact same controller pointer.
    //   (b) The controller reached via a *separately fetched* configuration copy
    //       is the same pointer too — i.e. each configuration copy strong-refs
    //       the one shared controller, it is not minted per configuration copy.
    //
    // What this does NOT prove (residual gap, manual checklist M2.2-G2): that
    // THIS controller instance is the one the live page's JS postMessage is
    // routed through. The only true proof of routing is a real JS round-trip on
    // a window-server-backed WKWebView with a loaded page + pumped run loop,
    // which is not headless. We assert instance stability/consistency here and
    // defer routing to the manual checklist.
    const wv = try WebView.init();
    defer wv.deinit();

    // (a) Same instance across two accessor calls.
    const ucc1 = wv.userContentController();
    const ucc2 = wv.userContentController();
    try std.testing.expect(ucc1.value != null);
    try std.testing.expectEqual(ucc1.value, ucc2.value);

    // (b) Same instance when reached through an independently-fetched
    // configuration copy. If each -[configuration] copy minted its own fresh
    // controller, these pointers would differ and the bridge would silently
    // register handlers on a controller the live webview never consults.
    const config_a = wv.ns_webview.msgSend(objc.Object, "configuration", .{});
    const config_b = wv.ns_webview.msgSend(objc.Object, "configuration", .{});
    const ucc_via_a = config_a.msgSend(objc.Object, "userContentController", .{});
    const ucc_via_b = config_b.msgSend(objc.Object, "userContentController", .{});
    try std.testing.expectEqual(ucc1.value, ucc_via_a.value);
    try std.testing.expectEqual(ucc1.value, ucc_via_b.value);
}

test "loadHTMLString() runs headless on a live WKWebView" {
    // loadHTMLString:baseURL: with a nil baseURL kicks off an async load on the
    // webview's process pool; it returns immediately and is safe headless (no
    // window server, no run loop pumped here). We only assert it does not crash
    // and the NSString plumbing is sound.
    const wv = try WebView.init();
    defer wv.deinit();

    try wv.loadHTMLString("<!doctype html><title>wkz</title><h1>hi</h1>");
}

test "nsString round-trips UTF-8 content (the plumbing loadHTMLString relies on)" {
    // loadHTMLString() only asserts no-crash; it cannot read the WKWebView's
    // loaded DOM headless. So exercise the helper it depends on directly: build a
    // +1 NSString from a known UTF-8 payload (incl. multibyte) and assert the
    // bytes survive the stringWithUTF8String:/retain round-trip. Guards against
    // the helper silently truncating or mangling the HTML before it reaches
    // WebKit. Pure Foundation, headless-safe.
    const NSString = objc.getClass("NSString").?;
    const payload: [:0]const u8 = "<h1>héllo • wkz</h1>";
    const s = nsString(NSString, payload);
    defer s.msgSend(void, "release", .{});

    try std.testing.expect(s.value != null);
    const back = s.msgSend([*:0]const u8, "UTF8String", .{});
    try std.testing.expectEqualStrings(payload, std.mem.span(back));
}

test "loadHTMLString() tolerates adversarial input headless" {
    // Adversarial bias: hostile HTML strings must not crash the loader or the
    // NSString plumbing. Empty input, a lone NUL-terminated empty body, and a
    // payload whose bytes are invalid UTF-8 all go through loadHTMLString().
    // +[NSString stringWithUTF8String:] returns nil on invalid UTF-8; -[retain]
    // on nil is a safe no-op, and -[WKWebView loadHTMLString:baseURL:] with a nil
    // string is likewise a safe no-op — so the contract is "returns without
    // crashing", which is what we assert here.
    const wv = try WebView.init();
    defer wv.deinit();

    // Empty string.
    try wv.loadHTMLString("");

    // Invalid UTF-8: 0xFF/0xFE are never valid UTF-8 lead bytes. The slice is
    // NUL-terminated so it satisfies the [:0]const u8 contract; the bytes before
    // the NUL are the hostile payload.
    const bad = [_:0]u8{ 0xff, 0xfe, 0xc0 };
    try wv.loadHTMLString(&bad);

    // A large but well-formed payload (oversized-ish): 64 KiB of valid HTML body.
    const big = try std.testing.allocator.allocSentinel(u8, 64 * 1024, 0);
    defer std.testing.allocator.free(big);
    @memset(big, 'a');
    try wv.loadHTMLString(big);
}

// --- loadURL: class resolution + selector verification (headless-safe) ---

test "NSURL and NSURLRequest classes resolve in the runtime" {
    // Pure runtime class lookups — no network, no window server.
    try std.testing.expect(objc.getClass("NSURL") != null);
    try std.testing.expect(objc.getClass("NSURLRequest") != null);
}

test "NSURL class responds to URLWithString: (class method)" {
    // `URLWithString:` is a class method (convenience constructor), so we query
    // the class object itself with `respondsToSelector:`, not
    // `instancesRespondToSelector:` (which only covers instance methods).
    const NSURL = objc.getClass("NSURL").?;
    try std.testing.expect(NSURL.msgSend(
        bool,
        "respondsToSelector:",
        .{objc.sel("URLWithString:").value},
    ));
}

test "NSURLRequest class responds to requestWithURL: (class method)" {
    // Same reasoning: `requestWithURL:` is a class convenience constructor.
    const NSURLRequest = objc.getClass("NSURLRequest").?;
    try std.testing.expect(NSURLRequest.msgSend(
        bool,
        "respondsToSelector:",
        .{objc.sel("requestWithURL:").value},
    ));
}

test "WKWebView instances respond to loadRequest:" {
    const WKWebView = objc.getClass("WKWebView").?;
    try std.testing.expect(WKWebView.msgSend(
        bool,
        "instancesRespondToSelector:",
        .{objc.sel("loadRequest:").value},
    ));
}

test "loadURL return type is WebView.Error!void" {
    // Compile-time pin: if the return type changes, this test breaks and the
    // caller (main.zig) will need to be updated in sync.
    const LoadURLRet = @typeInfo(@TypeOf(WebView.loadURL)).@"fn".return_type.?;
    try std.testing.expectEqual(Error!void, LoadURLRet);
}

test {
    std.testing.refAllDecls(@This());
}
