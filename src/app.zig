//! NSApplication bootstrap and lifecycle.
//!
//! Responsibility: create the shared NSApplication, set activation policy
//! (.regular), install the application menu (incl. Cmd+Q), and own the main run
//! loop. Everything here runs on the main thread.

const std = @import("std");
const objc = @import("objc");
const updater_mod = @import("updater.zig");

/// NSApplicationActivationPolicy values (AppKit/NSApplication.h).
/// We only need `.regular`: a normal app with a Dock icon and a menu bar.
const NSApplicationActivationPolicyRegular: c_long = 0;

/// Errors surfaced while bootstrapping the application.
pub const Error = error{
    /// A required AppKit class could not be looked up in the runtime. This
    /// only happens if AppKit failed to link/load, which is fatal.
    ClassNotFound,
};

/// The shared application object plus its bootstrap state.
///
/// Holds no owned Objective-C objects: `NSApp` is a process-wide singleton
/// owned by AppKit, and the menu objects are handed to AppKit (which retains
/// them) before being released here. There is therefore nothing to release in
/// a deinit, and none is provided.
pub const App = struct {
    /// The shared `NSApplication` instance (`NSApp`). Owned by AppKit, not us.
    ns_app: objc.Object,

    /// Create/obtain the shared application and configure it as a regular,
    /// menu-bar app with a Cmd+Q quit item.
    ///
    /// Must be called on the main thread. `+[NSApplication sharedApplication]`
    /// returns the process-wide singleton (no ownership transfer), so nothing
    /// here needs releasing on the returned `App`. The transient menu objects
    /// created during setup are released after AppKit takes ownership of them.
    pub fn init() Error!App {
        const NSApplication = objc.getClass("NSApplication") orelse
            return Error.ClassNotFound;

        // Process-wide singleton; not owned by us, do not release.
        const ns_app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});

        // Regular app: Dock icon + menu bar. setActivationPolicy: takes an
        // NSInteger (c_long) and returns BOOL; we ignore the result.
        _ = ns_app.msgSend(bool, "setActivationPolicy:", .{NSApplicationActivationPolicyRegular});

        try installMenu(ns_app);

        return .{ .ns_app = ns_app };
    }

    /// Enter the AppKit run loop (`-[NSApplication run]`). Blocks until the
    /// application terminates (e.g. via the Cmd+Q quit item). Must be called on
    /// the main thread.
    pub fn run(self: App) void {
        self.ns_app.msgSend(void, "run", .{});
    }

    /// Programmatically activate the app, bringing it to the foreground.
    /// Convenience for examples; main.zig (M1.5) calls this before `run`.
    /// Must be called on the main thread.
    pub fn activate(self: App) void {
        self.ns_app.msgSend(void, "activateIgnoringOtherApps:", .{true});
    }

    /// Add "Check for Updates…" to the app menu (first submenu of the main menu).
    /// Inserts the item at index 0 with a separator below it.
    ///
    /// Note (v0.1): the menu item's `checkForUpdates:` action is not wired to a
    /// live ObjC handler. In v0.1 the actual check is driven from the frontend via
    /// the bridge. The menu item serves as a visual hook for future wiring.
    ///
    /// `upd` is stored via the bridge context (`registerBridgeHandlers`); this
    /// function does not use it directly.
    ///
    /// Must be called on the main thread, after `App.init()`.
    pub fn addCheckForUpdatesItem(
        self: App,
        allocator: std.mem.Allocator,
        upd: *updater_mod.Updater,
    ) Error!void {
        _ = allocator;
        _ = upd;

        const NSMenuItem = objc.getClass("NSMenuItem") orelse return Error.ClassNotFound;

        const main_menu = self.ns_app.msgSend(objc.Object, "mainMenu", .{});
        if (main_menu.value == null) return Error.ClassNotFound;

        const app_item = main_menu.msgSend(objc.Object, "itemAtIndex:", .{@as(c_long, 0)});
        if (app_item.value == null) return Error.ClassNotFound;

        const app_menu = app_item.msgSend(objc.Object, "submenu", .{});
        if (app_menu.value == null) return Error.ClassNotFound;

        // Separator inserted first (at index 0), then item inserted at 0 (above separator).
        const sep = NSMenuItem.msgSend(objc.Object, "separatorItem", .{});
        app_menu.msgSend(void, "insertItem:atIndex:", .{ sep, @as(c_long, 0) });

        // "Check for Updates…" item — title built from a compile-time literal.
        const NSString = objc.getClass("NSString") orelse return Error.ClassNotFound;
        const title = nsString(NSString, "Check for Updates\u{2026}");
        defer title.msgSend(void, "release", .{});

        const empty_key = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{@as([*:0]const u8, "")});

        const item = NSMenuItem.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
            title,
            objc.sel("checkForUpdates:"),
            empty_key,
        });
        defer item.msgSend(void, "release", .{});

        app_menu.msgSend(void, "insertItem:atIndex:", .{ item, @as(c_long, 0) });
    }
};

/// Build the application menu with a single Quit item bound to Cmd+Q
/// (the `terminate:` selector) and install it as the app's main menu.
///
/// Ownership: each `alloc`/`init`'d Objective-C object created here is released
/// once AppKit retains it (menus retain their items; an app retains its main
/// menu; a menu item retains its submenu). `defer release` on every object
/// keeps the net retain count correct on all paths. No ARC.
fn installMenu(ns_app: objc.Object) Error!void {
    const NSMenu = objc.getClass("NSMenu") orelse return Error.ClassNotFound;
    const NSMenuItem = objc.getClass("NSMenuItem") orelse return Error.ClassNotFound;
    const NSString = objc.getClass("NSString") orelse return Error.ClassNotFound;

    // The menu bar itself.
    const main_menu = NSMenu.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer main_menu.msgSend(void, "release", .{});

    // The (titleless) container item that the application submenu hangs off of.
    const app_item = NSMenuItem.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer app_item.msgSend(void, "release", .{});
    // main_menu retains app_item.
    main_menu.msgSend(void, "addItem:", .{app_item});

    // The application submenu (holds the Quit item).
    const app_menu = NSMenu.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer app_menu.msgSend(void, "release", .{});
    // app_item retains app_menu as its submenu.
    app_item.msgSend(void, "setSubmenu:", .{app_menu});

    // Quit item: title "Quit", action terminate:, key equivalent "q" (Cmd+Q).
    const quit_title = nsString(NSString, "Quit");
    defer quit_title.msgSend(void, "release", .{});
    const quit_key = nsString(NSString, "q");
    defer quit_key.msgSend(void, "release", .{});

    const quit_item = NSMenuItem.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
        quit_title,
        objc.sel("terminate:"),
        quit_key,
    });
    defer quit_item.msgSend(void, "release", .{});
    // app_menu retains quit_item.
    app_menu.msgSend(void, "addItem:", .{quit_item});

    // The app retains its main menu.
    ns_app.msgSend(void, "setMainMenu:", .{main_menu});
}

/// Returns a `+1` NSString built from a UTF-8 C string. Caller owns it and must
/// `release` it. `-[NSString stringWithUTF8String:]` returns an autoreleased
/// string; since wkz drains no autorelease pool here, we `retain` it to get a
/// deterministic, ARC-free `+1` reference the caller releases explicitly.
fn nsString(NSString: objc.Class, comptime literal: [:0]const u8) objc.Object {
    const str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{literal.ptr});
    return str.msgSend(objc.Object, "retain", .{});
}

test "activation policy constant matches AppKit" {
    // NSApplicationActivationPolicyRegular == 0.
    try std.testing.expectEqual(@as(c_long, 0), NSApplicationActivationPolicyRegular);
}

// --- API-surface / type contract (compile-time, no AppKit calls) ---

test "App exposes the documented public API surface" {
    // App is a struct holding the singleton; verify its field type and that the
    // three public methods exist with the documented signatures. This is a
    // compile-time contract check — none of these are *called* here.
    try std.testing.expect(@hasField(App, "ns_app"));
    try std.testing.expectEqual(objc.Object, @FieldType(App, "ns_app"));

    // init() returns an error union over `Error`.
    const InitRet = @typeInfo(@TypeOf(App.init)).@"fn".return_type.?;
    try std.testing.expectEqual(Error!App, InitRet);

    // run/activate take an App by value and return void.
    try std.testing.expectEqual(void, @typeInfo(@TypeOf(App.run)).@"fn".return_type.?);
    try std.testing.expectEqual(void, @typeInfo(@TypeOf(App.activate)).@"fn".return_type.?);
}

test "Error set is exactly {ClassNotFound}" {
    // Guard against the error set silently growing; consumers exhaustively
    // switch on it.
    const fields = @typeInfo(Error).error_set.?;
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("ClassNotFound", fields[0].name);
}

test "required AppKit classes resolve in the runtime" {
    // init()/installMenu() look up these classes and return Error.ClassNotFound
    // if any is missing. Verifying they resolve documents that AppKit is linked
    // and that the success path of init() will not hit ClassNotFound. Pure
    // runtime lookups — no window-server connection, safe headless.
    try std.testing.expect(objc.getClass("NSApplication") != null);
    try std.testing.expect(objc.getClass("NSMenu") != null);
    try std.testing.expect(objc.getClass("NSMenuItem") != null);
    try std.testing.expect(objc.getClass("NSString") != null);
}

test "terminate: selector (Cmd+Q action) is registerable" {
    // The Quit item binds the `terminate:` selector. Registering it must yield a
    // non-null selector; a typo would silently produce a dead menu item.
    const sel = objc.sel("terminate:");
    try std.testing.expect(sel.value != null);
}

// --- Live bootstrap (headless-safe: probed to run + return without a window
//     server; see manual checklist for the GUI behaviour run() drives) ---

test "init() returns a configured App with a live NSApp singleton" {
    // Empirically headless-safe: sharedApplication, setActivationPolicy:, and
    // menu construction complete without a window server. We deliberately do
    // NOT call run() (blocks on the run loop) and do NOT call activate() in CI
    // (foregrounding is GUI behaviour covered by the manual checklist).
    const app = App.init() catch |e| {
        // ClassNotFound only if AppKit failed to link — fatal, surface it.
        std.debug.print("init() failed: {s}\n", .{@errorName(e)});
        return e;
    };

    // The singleton handle must be non-nil.
    try std.testing.expect(app.ns_app.value != null);

    // sharedApplication is idempotent: a second call returns the same pointer.
    const again = try App.init();
    try std.testing.expectEqual(app.ns_app.value, again.ns_app.value);

    // setMainMenu: ran inside init(); mainMenu must now be non-nil and its
    // first item must carry the application submenu we attached.
    const main_menu = app.ns_app.msgSend(objc.Object, "mainMenu", .{});
    try std.testing.expect(main_menu.value != null);

    const count = main_menu.msgSend(c_long, "numberOfItems", .{});
    try std.testing.expect(count >= 1);

    const app_item = main_menu.msgSend(objc.Object, "itemAtIndex:", .{@as(c_long, 0)});
    try std.testing.expect(app_item.value != null);
    const submenu = app_item.msgSend(objc.Object, "submenu", .{});
    try std.testing.expect(submenu.value != null);

    // The submenu holds exactly the Quit item, titled "Quit", bound to
    // terminate: with key equivalent "q".
    const sub_count = submenu.msgSend(c_long, "numberOfItems", .{});
    try std.testing.expectEqual(@as(c_long, 1), sub_count);

    const quit_item = submenu.msgSend(objc.Object, "itemAtIndex:", .{@as(c_long, 0)});
    try std.testing.expect(quit_item.value != null);
    try std.testing.expect(quit_item.msgSend(objc.c.SEL, "action", .{}) == objc.sel("terminate:").value);

    const key = quit_item.msgSend(objc.Object, "keyEquivalent", .{});
    const key_utf8 = key.msgSend([*:0]const u8, "UTF8String", .{});
    try std.testing.expectEqualStrings("q", std.mem.span(key_utf8));

    const title = quit_item.msgSend(objc.Object, "title", .{});
    const title_utf8 = title.msgSend([*:0]const u8, "UTF8String", .{});
    try std.testing.expectEqualStrings("Quit", std.mem.span(title_utf8));
}

test {
    std.testing.refAllDecls(@This());
}
