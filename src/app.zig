//! NSApplication bootstrap and lifecycle.
//!
//! Responsibility: create the shared NSApplication, set activation policy
//! (.regular), and own the main run loop. Menu installation is now handled
//! via setMenuBar / installDefaultMenu. Everything here runs on the main thread.

const std = @import("std");
const objc = @import("objc");
const menu_mod = @import("menu.zig");

const c = objc.c;

/// Module-level quit policy for WkzAppDelegate. One NSApp per process →
/// one delegate → module-level state is correct and avoids an ivar.
var app_quit_on_last_close: bool = false;

/// Process-unique name for the NSApplicationDelegate subclass.
const app_delegate_class_name: [:0]const u8 = "WkzAppDelegate";

/// Create (or look up) the WkzAppDelegate class.
/// Idempotent: second call returns the existing class. Lives for the process.
fn appDelegateClass() Error!objc.Class {
    if (objc.getClass(app_delegate_class_name)) |existing| return existing;
    const NSObject = objc.getClass("NSObject") orelse return Error.ClassNotFound;
    const cls = objc.allocateClassPair(NSObject, app_delegate_class_name) orelse
        return Error.ClassNotFound;
    errdefer objc.disposeClassPair(cls);
    std.debug.assert(cls.addMethod(
        "applicationShouldTerminateAfterLastWindowClosed:",
        impShouldTerminateAfterLastWindowClosed,
    ));
    objc.registerClassPair(cls);
    return cls;
}

/// IMP for applicationShouldTerminateAfterLastWindowClosed:.
/// Returns Zig `bool`; zig-objc encodes it as `B` (ObjC `BOOL`); arm64
/// ABI-compatible since `BOOL = i8` and Zig `bool` occupies one byte with
/// values 0/1. Reads the module-level quit policy set by setQuitOnLastWindowClosed.
fn impShouldTerminateAfterLastWindowClosed(
    self: c.id,
    _cmd: c.SEL,
    application: c.id,
) callconv(.c) bool {
    _ = self;
    _ = _cmd;
    _ = application;
    return app_quit_on_last_close;
}

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
/// Owns `delegate` (if set) and `menu_target` (if set). Both are released
/// in `deinit`. `ns_app` is the AppKit process singleton — not owned by us.
pub const App = struct {
    /// The shared `NSApplication` instance (`NSApp`). Owned by AppKit, not us.
    ns_app: objc.Object,
    /// The owned NSApplicationDelegate instance, if one has been set via
    /// `setQuitOnLastWindowClosed`. Null until that method is first called.
    /// Owned: must be released in `deinit`.
    delegate: ?objc.Object = null,
    /// Owned WkzMenuTarget instance (+1). Set by setMenuBar. Released in deinit.
    menu_target: ?objc.Object = null,
    /// Allocator used for the action table in setMenuBar. Stored so deinit can free it.
    menu_alloc: ?std.mem.Allocator = null,

    /// Create/obtain the shared application and configure it as a regular,
    /// menu-bar app. Menu installation is deferred to setMenuBar /
    /// installDefaultMenu.
    ///
    /// Must be called on the main thread. `+[NSApplication sharedApplication]`
    /// returns the process-wide singleton (no ownership transfer).
    pub fn init() Error!App {
        const NSApplication = objc.getClass("NSApplication") orelse
            return Error.ClassNotFound;

        // Process-wide singleton; not owned by us, do not release.
        const ns_app = NSApplication.msgSend(objc.Object, "sharedApplication", .{});

        // Regular app: Dock icon + menu bar. setActivationPolicy: takes an
        // NSInteger (c_long) and returns BOOL; we ignore the result.
        _ = ns_app.msgSend(bool, "setActivationPolicy:", .{NSApplicationActivationPolicyRegular});

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

    /// Build and install a full NSMenuBar from config. Allocates a WkzMenuTarget
    /// instance (if not already created) and an action table for zig/bridge items.
    /// Replaces any previously installed menu. Must be called before app.run(),
    /// on the main thread.
    pub fn setMenuBar(
        self: *App,
        allocator: std.mem.Allocator,
        config: menu_mod.MenuBarConfig,
    ) (Error || menu_mod.Error)!void {
        const cls = try menu_mod.menuTargetClass();
        const target_was_null = self.menu_target == null;
        if (target_was_null) {
            self.menu_target = cls.msgSend(objc.Object, "alloc", .{})
                .msgSend(objc.Object, "init", .{});
        }
        // On buildMenuBar error: release menu_target only if we allocated it this call.
        // If it was already set from a previous successful call, leave it alive for deinit.
        errdefer if (target_was_null) {
            self.menu_target.?.msgSend(void, "release", .{});
            self.menu_target = null;
        };
        // Free old action table with the allocator that owns it, then clear the
        // field so deinit is a no-op if buildMenuBar errors below.
        // self.menu_alloc is set to the new allocator only after buildMenuBar succeeds,
        // maintaining the invariant: menu_alloc == allocator that owns g_action_table.
        if (self.menu_alloc) |alloc| menu_mod.freeActionTable(alloc);
        self.menu_alloc = null;
        try menu_mod.buildMenuBar(allocator, self.ns_app, config, self.menu_target.?);
        self.menu_alloc = allocator;
    }

    /// Install a minimal menu: Hide/Show All + Quit [name] (Cmd+Q).
    /// Convenience for apps that don't need custom zig/bridge menu actions.
    /// Uses std.heap.page_allocator — safe to store in menu_alloc since
    /// page_allocator is a statically-known singleton (no stack state).
    /// Must be called before app.run(), on the main thread.
    pub fn installDefaultMenu(self: *App, name: [:0]const u8) (Error || menu_mod.Error)!void {
        try self.setMenuBar(std.heap.page_allocator, .{
            .app = .{ .name = name },
        });
    }

    /// Release owned ObjC objects and free the menu action table if allocated.
    /// Does NOT release ns_app — it is the AppKit process singleton.
    pub fn deinit(self: App) void {
        if (self.delegate) |d| d.msgSend(void, "release", .{});
        if (self.menu_target) |t| t.msgSend(void, "release", .{});
        if (self.menu_alloc) |alloc| menu_mod.freeActionTable(alloc);
    }

    /// Wire quit-on-last-window-close behaviour. Registers WkzAppDelegate (once,
    /// idempotent), creates a delegate instance, and sets it as NSApp's delegate.
    /// Replaces any previously set delegate (releases the old one first).
    /// Must be called on the main thread, after `App.init()`.
    pub fn setQuitOnLastWindowClosed(self: *App, enabled: bool) Error!void {
        const cls = try appDelegateClass();
        app_quit_on_last_close = enabled;
        if (self.delegate) |old| {
            old.msgSend(void, "release", .{});
            self.delegate = null;
        }
        const delegate = cls.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "init", .{});
        self.delegate = delegate;
        self.ns_app.msgSend(void, "setDelegate:", .{delegate});
    }
};

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
    // init() looks up NSApplication and returns Error.ClassNotFound if missing.
    // Verifying they resolve documents that AppKit is linked and that the
    // success path of init() will not hit ClassNotFound. Pure runtime lookups —
    // no window-server connection, safe headless.
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
    var app = App.init() catch |e| {
        std.debug.print("init() failed: {s}\n", .{@errorName(e)});
        return e;
    };
    defer app.deinit();

    // Singleton handle must be non-nil.
    try std.testing.expect(app.ns_app.value != null);

    // sharedApplication is idempotent.
    const again = try App.init();
    try std.testing.expectEqual(app.ns_app.value, again.ns_app.value);

    // init() no longer installs a menu — installDefaultMenu does.
    try app.installDefaultMenu("TestApp");

    const main_menu = app.ns_app.msgSend(objc.Object, "mainMenu", .{});
    try std.testing.expect(main_menu.value != null);
    const count = main_menu.msgSend(c_long, "numberOfItems", .{});
    try std.testing.expect(count >= 1);

    const app_item = main_menu.msgSend(objc.Object, "itemAtIndex:", .{@as(c_long, 0)});
    try std.testing.expect(app_item.value != null);
    const submenu = app_item.msgSend(objc.Object, "submenu", .{});
    try std.testing.expect(submenu.value != null);

    // App menu must contain at least Hide + HideOthers + ShowAll + Quit = 4 items + separator.
    const sub_count = submenu.msgSend(c_long, "numberOfItems", .{});
    try std.testing.expect(sub_count >= 4);

    // Last item must be "Quit TestApp" bound to terminate:.
    const quit_item = submenu.msgSend(objc.Object, "itemAtIndex:", .{sub_count - 1});
    try std.testing.expect(quit_item.msgSend(c.SEL, "action", .{}) == objc.sel("terminate:").value);

    // Key equivalent must be "q" (Cmd+Q).
    const quit_key = quit_item.msgSend(objc.Object, "keyEquivalent", .{});
    const quit_key_utf8 = quit_key.msgSend([*:0]const u8, "UTF8String", .{});
    try std.testing.expectEqualStrings("q", std.mem.span(quit_key_utf8));

    // Title must be "Quit TestApp" — verifies config.app.name propagated.
    const quit_title = quit_item.msgSend(objc.Object, "title", .{});
    const quit_title_utf8 = quit_title.msgSend([*:0]const u8, "UTF8String", .{});
    try std.testing.expectEqualStrings("Quit TestApp", std.mem.span(quit_title_utf8));
}

test "App struct has delegate field of type ?objc.Object" {
    try std.testing.expect(@hasField(App, "delegate"));
    try std.testing.expectEqual(?objc.Object, @FieldType(App, "delegate"));
}

test "App.deinit has correct return type and takes App by value" {
    try std.testing.expectEqual(void, @typeInfo(@TypeOf(App.deinit)).@"fn".return_type.?);
    try std.testing.expectEqual(App, @typeInfo(@TypeOf(App.deinit)).@"fn".params[0].type.?);
}

test "appDelegateClass registers WkzAppDelegate with the correct selector" {
    const cls = try appDelegateClass();
    try std.testing.expect(objc.getClass("WkzAppDelegate") != null);
    try std.testing.expectEqual(objc.getClass("WkzAppDelegate").?.value, cls.value);
    try std.testing.expect(cls.msgSend(
        bool,
        "instancesRespondToSelector:",
        .{objc.sel("applicationShouldTerminateAfterLastWindowClosed:").value},
    ));
}

test "appDelegateClass is idempotent" {
    const a = try appDelegateClass();
    const b = try appDelegateClass();
    try std.testing.expectEqual(a.value, b.value);
}

test "setQuitOnLastWindowClosed signature matches spec" {
    const Ret = @typeInfo(@TypeOf(App.setQuitOnLastWindowClosed)).@"fn".return_type.?;
    try std.testing.expectEqual(Error!void, Ret);
}

test "App has menu_target and menu_alloc fields" {
    try std.testing.expect(@hasField(App, "menu_target"));
    try std.testing.expect(@hasField(App, "menu_alloc"));
    try std.testing.expectEqual(?objc.Object, @FieldType(App, "menu_target"));
    try std.testing.expectEqual(?std.mem.Allocator, @FieldType(App, "menu_alloc"));
}

test "App.setMenuBar takes *App, allocator, MenuBarConfig" {
    const params = @typeInfo(@TypeOf(App.setMenuBar)).@"fn".params;
    try std.testing.expectEqual(@as(usize, 3), params.len);
}

test "App.installDefaultMenu takes *App and [:0]const u8" {
    const params = @typeInfo(@TypeOf(App.installDefaultMenu)).@"fn".params;
    try std.testing.expectEqual(@as(usize, 2), params.len);
}

test {
    std.testing.refAllDecls(@This());
}
