//! NSMenuBar construction for wkz applications.
//!
//! Responsibility: define the public MenuAction / MenuItem / AppMenuConfig /
//! MenuBarConfig types, own the WkzMenuTarget ObjC class and its runtime
//! action table, and expose buildMenuBar for App.setMenuBar to call.
//! Main thread only. No ARC: see ownership notes on each function.

const std = @import("std");
const bridge_mod = @import("bridge.zig");
const objc = @import("objc");
const c = objc.c;

pub const MenuAction = union(enum) {
    /// Native AppKit selector forwarded via the first-responder chain.
    /// e.g. "terminate:", "undo:", "copy:", "miniaturize:", "performClose:"
    selector: [:0]const u8,

    /// Zig callback. Fires on the main thread (AppKit run loop guarantee).
    /// `ctx` must remain valid for the lifetime of the menu (process lifetime
    /// for static menus). Not safe to capture stack pointers that may unwind.
    zig: struct {
        ctx: *anyopaque,
        callback: *const fn (*anyopaque) void,
    },

    /// Dispatch a call through the wkz JS bridge. Equivalent to the JS client
    /// calling `invoke(method, {})`. `bridge` must outlive the menu bar.
    /// `method` is copied into a pre-built JSON payload during setMenuBar;
    /// the original slice need not remain valid after setMenuBar returns.
    bridge: struct {
        bridge: *bridge_mod.Bridge,
        method: [:0]const u8,
    },
};

pub const MenuItem = union(enum) {
    separator,

    item: struct {
        /// Null-terminated title. Caller owns localisation.
        title: [:0]const u8,
        /// Key equivalent (single char). "" = no shortcut. Cmd modifier implicit.
        key: [:0]const u8,
        action: MenuAction,
    },

    submenu: struct {
        title: [:0]const u8,
        /// Caller owns this slice; it must remain valid for the lifetime of the menu bar.
        items: []const MenuItem,
    },
};

pub const AppMenuConfig = struct {
    /// App name shown in the menu title and auto-generated "About / Quit" labels.
    name: [:0]const u8,
    /// "About [name]…" item. null = absent.
    about: ?MenuAction = null,
    /// "Check for Updates…" item. null = absent.
    check_for_updates: ?MenuAction = null,
    /// "Preferences…" item (Cmd+,). null = absent.
    preferences: ?MenuAction = null,
    /// Additional items inserted after Preferences, before the Hide/Quit block.
    extra_items: []const MenuItem = &.{},
};

pub const MenuBarConfig = struct {
    app: AppMenuConfig,
    /// Additional top-level menus (File, View, etc.) after the app menu.
    menus: []const struct {
        title: [:0]const u8,
        items: []const MenuItem,
    } = &.{},
    /// Insert a standard Edit menu (Undo/Redo/Cut/Copy/Paste/Select All)
    /// using native AppKit selectors → WKWebView handles them automatically.
    standard_edit_menu: bool = false,
    /// Insert a standard Window menu (Minimize/Zoom/Close) using native selectors.
    standard_window_menu: bool = false,
};

/// Errors from menu construction.
pub const Error = error{
    /// A required AppKit class could not be looked up. Fatal if AppKit is linked.
    ClassNotFound,
    /// Memory allocation failed while building the action table or JSON payloads.
    OutOfMemory,
};

/// Runtime payload for a single zig or bridge menu item.
/// Selector items do not appear in this table — they use target=nil so
/// AppKit forwards them via the first-responder chain without calling our IMP.
const ActionEntry = union(enum) {
    zig: struct {
        ctx: *anyopaque,
        callback: *const fn (*anyopaque) void,
    },
    bridge: struct {
        bridge_ptr: *bridge_mod.Bridge,
        /// Pre-built JSON payload: {"method":"<name>","params":{}}
        /// Owned by the action table slice, freed in freeActionTable.
        json: []u8,
    },
};

/// Heap-allocated slice of ActionEntry, indexed by NSMenuItem.tag.
/// Set by buildMenuBar, freed by freeActionTable. Module-level because one
/// NSApp → one menu bar → one action table per process.
var g_action_table: []ActionEntry = &.{};

/// Free all bridge json payloads in the table, then free the slice itself.
/// Called from App.deinit. Idempotent (resets g_action_table to empty slice).
/// Internal wkz API — called by App.setMenuBar and App.deinit. Not part of the stable consumer surface.
pub fn freeActionTable(allocator: std.mem.Allocator) void {
    for (g_action_table) |*entry| {
        switch (entry.*) {
            .bridge => |*b| allocator.free(b.json),
            .zig => {},
        }
    }
    if (g_action_table.len > 0) allocator.free(g_action_table);
    g_action_table = &.{};
}

const menu_target_class_name: [:0]const u8 = "WkzMenuTarget";

/// Create (or look up) the WkzMenuTarget class. Idempotent: second call returns
/// the existing class. No ivars — action dispatch goes through g_action_table.
pub fn menuTargetClass() Error!objc.Class {
    if (objc.getClass(menu_target_class_name)) |existing| return existing;
    const NSObject = objc.getClass("NSObject") orelse return Error.ClassNotFound;
    const cls = objc.allocateClassPair(NSObject, menu_target_class_name) orelse
        return Error.ClassNotFound;
    errdefer objc.disposeClassPair(cls);
    std.debug.assert(cls.addMethod("menuAction:", impMenuAction));
    objc.registerClassPair(cls);
    return cls;
}

/// IMP for -[WkzMenuTarget menuAction:].
/// Reads sender.tag, indexes g_action_table, dispatches the action.
/// Always fires on the main thread (AppKit run loop guarantee).
fn impMenuAction(
    self: c.id,
    _cmd: c.SEL,
    sender: c.id,
) callconv(.c) void {
    _ = self;
    _ = _cmd;
    const item = objc.Object{ .value = sender };
    const tag = item.msgSend(c_long, "tag", .{});
    if (tag < 0 or @as(usize, @intCast(tag)) >= g_action_table.len) return;
    const entry = &g_action_table[@intCast(tag)];
    switch (entry.*) {
        .zig => |z| z.callback(z.ctx),
        .bridge => |b| b.bridge_ptr.dispatchSlice(b.json) catch |err|
            std.log.warn("[wkz] menu bridge dispatch failed: {s}", .{@errorName(err)}),
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Returns a +1 NSString from a null-terminated Zig slice. Caller must release.
/// Uses stringWithUTF8String: + retain (same pattern as app.zig nsString).
fn nsStringZ(NSString: objc.Class, s: [:0]const u8) objc.Object {
    const str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{s.ptr});
    return str.msgSend(objc.Object, "retain", .{});
}

/// Count all zig/bridge MenuAction items recursively in a MenuItem slice.
fn countCustomActions(items: []const MenuItem) usize {
    var n: usize = 0;
    for (items) |item| {
        switch (item) {
            .separator => {},
            .item => |it| switch (it.action) {
                .zig, .bridge => n += 1,
                .selector => {},
            },
            .submenu => |sub| n += countCustomActions(sub.items),
        }
    }
    return n;
}

/// Count all zig/bridge actions in a full MenuBarConfig.
fn countConfigActions(config: MenuBarConfig) usize {
    var n: usize = 0;
    for ([_]?MenuAction{ config.app.about, config.app.check_for_updates, config.app.preferences }) |opt| {
        if (opt) |a| switch (a) {
            .zig, .bridge => n += 1,
            .selector => {},
        };
    }
    n += countCustomActions(config.app.extra_items);
    for (config.menus) |m| n += countCustomActions(m.items);
    return n;
}

/// Append items to ns_menu. Returns updated tag_counter.
/// entries must be pre-allocated with enough capacity.
/// On OOM, frees any bridge json written by this call before returning; the
/// caller's errdefer covers entries[0..tag_counter].
fn addMenuItems(
    allocator: std.mem.Allocator,
    NSMenuItem: objc.Class,
    NSString: objc.Class,
    ns_menu: objc.Object,
    menu_target: objc.Object,
    items: []const MenuItem,
    entries: []ActionEntry,
    tag_counter: usize,
) Error!usize {
    var tag: usize = tag_counter;
    // Free any bridge json entries we write before erroring. Covers the range
    // [tag_counter..tag] — entries written by this call before the failure.
    // On recursive submenu calls, each level's errdefer covers its own range,
    // so the full [tag_counter..final_tag] is freed without double-frees.
    errdefer {
        for (entries[tag_counter..tag]) |*e| {
            switch (e.*) {
                .bridge => |b| allocator.free(b.json),
                .zig => {},
            }
        }
    }
    for (items) |item| {
        switch (item) {
            .separator => {
                const sep = NSMenuItem.msgSend(objc.Object, "separatorItem", .{});
                ns_menu.msgSend(void, "addItem:", .{sep});
            },
            .item => |it| {
                const title = nsStringZ(NSString, it.title);
                defer title.msgSend(void, "release", .{});
                const key = nsStringZ(NSString, it.key);
                defer key.msgSend(void, "release", .{});

                const ns_item = NSMenuItem.msgSend(objc.Object, "alloc", .{})
                    .msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
                    title, objc.sel("menuAction:"), key,
                });
                defer ns_item.msgSend(void, "release", .{});

                switch (it.action) {
                    .selector => |sel_name| {
                        ns_item.msgSend(void, "setAction:", .{objc.sel(sel_name)});
                        ns_item.msgSend(void, "setTarget:", .{@as(?*anyopaque, null)});
                    },
                    .zig => |z| {
                        entries[tag] = .{ .zig = .{ .ctx = z.ctx, .callback = z.callback } };
                        ns_item.msgSend(void, "setTag:", .{@as(c_long, @intCast(tag))});
                        ns_item.msgSend(void, "setTarget:", .{menu_target});
                        tag += 1;
                    },
                    .bridge => |b| {
                        const json = std.fmt.allocPrint(
                            allocator,
                            "{{\"method\":\"{s}\",\"params\":{{}}}}",
                            .{b.method},
                        ) catch return Error.OutOfMemory;
                        entries[tag] = .{ .bridge = .{ .bridge_ptr = b.bridge, .json = json } };
                        ns_item.msgSend(void, "setTag:", .{@as(c_long, @intCast(tag))});
                        ns_item.msgSend(void, "setTarget:", .{menu_target});
                        tag += 1;
                    },
                }
                ns_menu.msgSend(void, "addItem:", .{ns_item});
            },
            .submenu => |sub| {
                const NSMenu = objc.getClass("NSMenu") orelse return Error.ClassNotFound;
                const sub_title = nsStringZ(NSString, sub.title);
                defer sub_title.msgSend(void, "release", .{});

                const ns_sub = NSMenu.msgSend(objc.Object, "alloc", .{})
                    .msgSend(objc.Object, "initWithTitle:", .{sub_title});
                defer ns_sub.msgSend(void, "release", .{});

                const empty_key = nsStringZ(NSString, "");
                defer empty_key.msgSend(void, "release", .{});

                const parent_item = NSMenuItem.msgSend(objc.Object, "alloc", .{})
                    .msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
                    sub_title, @as(c.SEL, @ptrFromInt(0)), empty_key,
                });
                defer parent_item.msgSend(void, "release", .{});

                tag = try addMenuItems(allocator, NSMenuItem, NSString, ns_sub, menu_target, sub.items, entries, tag);
                parent_item.msgSend(void, "setSubmenu:", .{ns_sub});
                ns_menu.msgSend(void, "addItem:", .{parent_item});
            },
        }
    }
    return tag;
}

// EditItem and WinItem are file-level types (Zig 0.16 does not allow const
// struct declarations inside functions in all contexts).
const EditItem = struct { t: [:0]const u8, k: [:0]const u8, s: [:0]const u8 };
const WinItem = struct { t: [:0]const u8, k: [:0]const u8, s: [:0]const u8 };

/// Build and install a complete NSMenuBar from config. Allocates g_action_table.
/// Must be called on the main thread, before app.run().
/// On error, any ObjC objects already added to menus are released by their menus.
/// On OOM, any bridge json payloads already written to `entries` are freed before returning.
/// Internal wkz API — called by App.setMenuBar. Not part of the stable consumer surface.
pub fn buildMenuBar(
    allocator: std.mem.Allocator,
    ns_app: objc.Object,
    config: MenuBarConfig,
    menu_target: objc.Object,
) Error!void {
    const NSMenu = objc.getClass("NSMenu") orelse return Error.ClassNotFound;
    const NSMenuItem = objc.getClass("NSMenuItem") orelse return Error.ClassNotFound;
    const NSString = objc.getClass("NSString") orelse return Error.ClassNotFound;

    // Allocate action table.
    const n_entries = countConfigActions(config);
    const entries: []ActionEntry = if (n_entries > 0)
        allocator.alloc(ActionEntry, n_entries) catch return Error.OutOfMemory
    else
        &[_]ActionEntry{};
    var tag: usize = 0;
    errdefer {
        for (entries[0..tag]) |*e| {
            switch (e.*) {
                .bridge => |b| allocator.free(b.json),
                .zig => {},
            }
        }
        if (n_entries > 0) allocator.free(entries);
    }

    // Main menu bar.
    const main_menu = NSMenu.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer main_menu.msgSend(void, "release", .{});

    // ── App menu ──────────────────────────────────────────────────────────────
    {
        const app_item = NSMenuItem.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "init", .{});
        defer app_item.msgSend(void, "release", .{});

        const app_menu = NSMenu.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "init", .{});
        defer app_menu.msgSend(void, "release", .{});

        // About [name]…
        if (config.app.about) |a| {
            const about_label = std.fmt.allocPrintSentinel(allocator, "About {s}\u{2026}", .{config.app.name}, 0) catch return Error.OutOfMemory;
            defer allocator.free(about_label);
            const title_ns = nsStringZ(NSString, about_label);
            defer title_ns.msgSend(void, "release", .{});
            const key_ns = nsStringZ(NSString, "");
            defer key_ns.msgSend(void, "release", .{});
            const ns_item = NSMenuItem.msgSend(objc.Object, "alloc", .{})
                .msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
                title_ns, objc.sel("menuAction:"), key_ns,
            });
            defer ns_item.msgSend(void, "release", .{});
            switch (a) {
                .selector => |sel_name| {
                    ns_item.msgSend(void, "setAction:", .{objc.sel(sel_name)});
                    ns_item.msgSend(void, "setTarget:", .{@as(?*anyopaque, null)});
                },
                .zig => |z| {
                    entries[tag] = .{ .zig = .{ .ctx = z.ctx, .callback = z.callback } };
                    ns_item.msgSend(void, "setTag:", .{@as(c_long, @intCast(tag))});
                    ns_item.msgSend(void, "setTarget:", .{menu_target});
                    tag += 1;
                },
                .bridge => |b| {
                    const json = std.fmt.allocPrint(allocator, "{{\"method\":\"{s}\",\"params\":{{}}}}", .{b.method}) catch return Error.OutOfMemory;
                    entries[tag] = .{ .bridge = .{ .bridge_ptr = b.bridge, .json = json } };
                    ns_item.msgSend(void, "setTag:", .{@as(c_long, @intCast(tag))});
                    ns_item.msgSend(void, "setTarget:", .{menu_target});
                    tag += 1;
                },
            }
            app_menu.msgSend(void, "addItem:", .{ns_item});
        }

        // Check for Updates…
        if (config.app.check_for_updates) |a| {
            const title_ns = nsStringZ(NSString, "Check for Updates\u{2026}");
            defer title_ns.msgSend(void, "release", .{});
            const key_ns = nsStringZ(NSString, "");
            defer key_ns.msgSend(void, "release", .{});
            const ns_item = NSMenuItem.msgSend(objc.Object, "alloc", .{})
                .msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
                title_ns, objc.sel("menuAction:"), key_ns,
            });
            defer ns_item.msgSend(void, "release", .{});
            switch (a) {
                .selector => |sel_name| {
                    ns_item.msgSend(void, "setAction:", .{objc.sel(sel_name)});
                    ns_item.msgSend(void, "setTarget:", .{@as(?*anyopaque, null)});
                },
                .zig => |z| {
                    entries[tag] = .{ .zig = .{ .ctx = z.ctx, .callback = z.callback } };
                    ns_item.msgSend(void, "setTag:", .{@as(c_long, @intCast(tag))});
                    ns_item.msgSend(void, "setTarget:", .{menu_target});
                    tag += 1;
                },
                .bridge => |b| {
                    const json = std.fmt.allocPrint(allocator, "{{\"method\":\"{s}\",\"params\":{{}}}}", .{b.method}) catch return Error.OutOfMemory;
                    entries[tag] = .{ .bridge = .{ .bridge_ptr = b.bridge, .json = json } };
                    ns_item.msgSend(void, "setTag:", .{@as(c_long, @intCast(tag))});
                    ns_item.msgSend(void, "setTarget:", .{menu_target});
                    tag += 1;
                },
            }
            app_menu.msgSend(void, "addItem:", .{ns_item});
        }

        // Preferences… (Cmd+,)
        if (config.app.preferences) |a| {
            const title_ns = nsStringZ(NSString, "Preferences\u{2026}");
            defer title_ns.msgSend(void, "release", .{});
            const key_ns = nsStringZ(NSString, ",");
            defer key_ns.msgSend(void, "release", .{});
            const ns_item = NSMenuItem.msgSend(objc.Object, "alloc", .{})
                .msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
                title_ns, objc.sel("menuAction:"), key_ns,
            });
            defer ns_item.msgSend(void, "release", .{});
            switch (a) {
                .selector => |sel_name| {
                    ns_item.msgSend(void, "setAction:", .{objc.sel(sel_name)});
                    ns_item.msgSend(void, "setTarget:", .{@as(?*anyopaque, null)});
                },
                .zig => |z| {
                    entries[tag] = .{ .zig = .{ .ctx = z.ctx, .callback = z.callback } };
                    ns_item.msgSend(void, "setTag:", .{@as(c_long, @intCast(tag))});
                    ns_item.msgSend(void, "setTarget:", .{menu_target});
                    tag += 1;
                },
                .bridge => |b| {
                    const json = std.fmt.allocPrint(allocator, "{{\"method\":\"{s}\",\"params\":{{}}}}", .{b.method}) catch return Error.OutOfMemory;
                    entries[tag] = .{ .bridge = .{ .bridge_ptr = b.bridge, .json = json } };
                    ns_item.msgSend(void, "setTag:", .{@as(c_long, @intCast(tag))});
                    ns_item.msgSend(void, "setTarget:", .{menu_target});
                    tag += 1;
                },
            }
            app_menu.msgSend(void, "addItem:", .{ns_item});
        }

        // Extra items (with leading separator if any present).
        if (config.app.extra_items.len > 0) {
            const sep = NSMenuItem.msgSend(objc.Object, "separatorItem", .{});
            app_menu.msgSend(void, "addItem:", .{sep});
            tag = try addMenuItems(allocator, NSMenuItem, NSString, app_menu, menu_target, config.app.extra_items, entries, tag);
        }

        // Hide / Hide Others / Show All / Quit — always present.
        {
            const sep = NSMenuItem.msgSend(objc.Object, "separatorItem", .{});
            app_menu.msgSend(void, "addItem:", .{sep});

            // Hide [name] (Cmd+H)
            const hide_label = std.fmt.allocPrintSentinel(allocator, "Hide {s}", .{config.app.name}, 0) catch return Error.OutOfMemory;
            defer allocator.free(hide_label);
            const hide_title = nsStringZ(NSString, hide_label);
            defer hide_title.msgSend(void, "release", .{});
            const hide_key = nsStringZ(NSString, "h");
            defer hide_key.msgSend(void, "release", .{});
            const hide_item = NSMenuItem.msgSend(objc.Object, "alloc", .{})
                .msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
                hide_title, objc.sel("hide:"), hide_key,
            });
            defer hide_item.msgSend(void, "release", .{});
            app_menu.msgSend(void, "addItem:", .{hide_item});

            // Hide Others (Cmd+Option+H)
            const ho_title = nsStringZ(NSString, "Hide Others");
            defer ho_title.msgSend(void, "release", .{});
            const ho_key = nsStringZ(NSString, "h");
            defer ho_key.msgSend(void, "release", .{});
            const ho_item = NSMenuItem.msgSend(objc.Object, "alloc", .{})
                .msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
                ho_title, objc.sel("hideOtherApplications:"), ho_key,
            });
            defer ho_item.msgSend(void, "release", .{});
            // NSEventModifierFlagOption (1<<19) | NSEventModifierFlagCommand (1<<20)
            ho_item.msgSend(void, "setKeyEquivalentModifierMask:", .{@as(c_ulong, (1 << 19) | (1 << 20))});
            app_menu.msgSend(void, "addItem:", .{ho_item});

            // Show All
            const sa_title = nsStringZ(NSString, "Show All");
            defer sa_title.msgSend(void, "release", .{});
            const sa_key = nsStringZ(NSString, "");
            defer sa_key.msgSend(void, "release", .{});
            const sa_item = NSMenuItem.msgSend(objc.Object, "alloc", .{})
                .msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
                sa_title, objc.sel("unhideAllApplications:"), sa_key,
            });
            defer sa_item.msgSend(void, "release", .{});
            app_menu.msgSend(void, "addItem:", .{sa_item});

            const sep2 = NSMenuItem.msgSend(objc.Object, "separatorItem", .{});
            app_menu.msgSend(void, "addItem:", .{sep2});

            // Quit [name] (Cmd+Q)
            const quit_label = std.fmt.allocPrintSentinel(allocator, "Quit {s}", .{config.app.name}, 0) catch return Error.OutOfMemory;
            defer allocator.free(quit_label);
            const quit_title = nsStringZ(NSString, quit_label);
            defer quit_title.msgSend(void, "release", .{});
            const quit_key = nsStringZ(NSString, "q");
            defer quit_key.msgSend(void, "release", .{});
            const quit_item = NSMenuItem.msgSend(objc.Object, "alloc", .{})
                .msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
                quit_title, objc.sel("terminate:"), quit_key,
            });
            defer quit_item.msgSend(void, "release", .{});
            app_menu.msgSend(void, "addItem:", .{quit_item});
        }

        app_item.msgSend(void, "setSubmenu:", .{app_menu});
        main_menu.msgSend(void, "addItem:", .{app_item});
    }

    // ── Custom top-level menus ────────────────────────────────────────────────
    for (config.menus) |m| {
        const menu_title_ns = nsStringZ(NSString, m.title);
        defer menu_title_ns.msgSend(void, "release", .{});
        const ns_menu = NSMenu.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithTitle:", .{menu_title_ns});
        defer ns_menu.msgSend(void, "release", .{});
        tag = try addMenuItems(allocator, NSMenuItem, NSString, ns_menu, menu_target, m.items, entries, tag);

        const empty_key = nsStringZ(NSString, "");
        defer empty_key.msgSend(void, "release", .{});
        const top_item = NSMenuItem.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
            menu_title_ns, @as(c.SEL, @ptrFromInt(0)), empty_key,
        });
        defer top_item.msgSend(void, "release", .{});
        top_item.msgSend(void, "setSubmenu:", .{ns_menu});
        main_menu.msgSend(void, "addItem:", .{top_item});
    }

    // ── Standard Edit menu ────────────────────────────────────────────────────
    if (config.standard_edit_menu) {
        const edit_title_ns = nsStringZ(NSString, "Edit");
        defer edit_title_ns.msgSend(void, "release", .{});
        const edit_menu = NSMenu.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithTitle:", .{edit_title_ns});
        defer edit_menu.msgSend(void, "release", .{});

        const empty_key_e = nsStringZ(NSString, "");
        defer empty_key_e.msgSend(void, "release", .{});
        const edit_top = NSMenuItem.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
            edit_title_ns, @as(c.SEL, @ptrFromInt(0)), empty_key_e,
        });
        defer edit_top.msgSend(void, "release", .{});

        for ([_]EditItem{
            .{ .t = "Undo", .k = "z", .s = "undo:" },
            .{ .t = "Redo", .k = "Z", .s = "redo:" },
        }) |ei| {
            const t = nsStringZ(NSString, ei.t);
            defer t.msgSend(void, "release", .{});
            const k = nsStringZ(NSString, ei.k);
            defer k.msgSend(void, "release", .{});
            const it = NSMenuItem.msgSend(objc.Object, "alloc", .{})
                .msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{ t, objc.sel(ei.s), k });
            defer it.msgSend(void, "release", .{});
            edit_menu.msgSend(void, "addItem:", .{it});
        }
        const sep_e = NSMenuItem.msgSend(objc.Object, "separatorItem", .{});
        edit_menu.msgSend(void, "addItem:", .{sep_e});
        for ([_]EditItem{
            .{ .t = "Cut", .k = "x", .s = "cut:" },
            .{ .t = "Copy", .k = "c", .s = "copy:" },
            .{ .t = "Paste", .k = "v", .s = "paste:" },
            .{ .t = "Select All", .k = "a", .s = "selectAll:" },
        }) |ei| {
            const t = nsStringZ(NSString, ei.t);
            defer t.msgSend(void, "release", .{});
            const k = nsStringZ(NSString, ei.k);
            defer k.msgSend(void, "release", .{});
            const it = NSMenuItem.msgSend(objc.Object, "alloc", .{})
                .msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{ t, objc.sel(ei.s), k });
            defer it.msgSend(void, "release", .{});
            edit_menu.msgSend(void, "addItem:", .{it});
        }
        edit_top.msgSend(void, "setSubmenu:", .{edit_menu});
        main_menu.msgSend(void, "addItem:", .{edit_top});
    }

    // ── Standard Window menu ──────────────────────────────────────────────────
    if (config.standard_window_menu) {
        const win_title_ns = nsStringZ(NSString, "Window");
        defer win_title_ns.msgSend(void, "release", .{});
        const win_menu = NSMenu.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithTitle:", .{win_title_ns});
        defer win_menu.msgSend(void, "release", .{});

        const empty_key_w = nsStringZ(NSString, "");
        defer empty_key_w.msgSend(void, "release", .{});
        const win_top = NSMenuItem.msgSend(objc.Object, "alloc", .{})
            .msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{
            win_title_ns, @as(c.SEL, @ptrFromInt(0)), empty_key_w,
        });
        defer win_top.msgSend(void, "release", .{});

        for ([_]WinItem{
            .{ .t = "Minimize", .k = "m", .s = "miniaturize:" },
            .{ .t = "Zoom", .k = "", .s = "zoom:" },
            .{ .t = "Close", .k = "w", .s = "performClose:" },
        }) |wi| {
            const t = nsStringZ(NSString, wi.t);
            defer t.msgSend(void, "release", .{});
            const k = nsStringZ(NSString, wi.k);
            defer k.msgSend(void, "release", .{});
            const it = NSMenuItem.msgSend(objc.Object, "alloc", .{})
                .msgSend(objc.Object, "initWithTitle:action:keyEquivalent:", .{ t, objc.sel(wi.s), k });
            defer it.msgSend(void, "release", .{});
            win_menu.msgSend(void, "addItem:", .{it});
        }
        win_top.msgSend(void, "setSubmenu:", .{win_menu});
        main_menu.msgSend(void, "addItem:", .{win_top});
    }

    // Install menu bar and commit action table.
    ns_app.msgSend(void, "setMainMenu:", .{main_menu});
    g_action_table = entries;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "NSMenu and NSMenuItem classes resolve (AppKit linked)" {
    try std.testing.expect(objc.getClass("NSMenu") != null);
    try std.testing.expect(objc.getClass("NSMenuItem") != null);
}

test "countConfigActions returns 0 for a config with only selector actions" {
    const cfg = MenuBarConfig{
        .app = .{
            .name = "TestApp",
            .about = MenuAction{ .selector = "orderFrontStandardAboutPanel:" },
        },
    };
    try std.testing.expectEqual(@as(usize, 0), countConfigActions(cfg));
}

test "countConfigActions counts zig actions" {
    var fired = false;
    const cb: *const fn (*anyopaque) void = &struct {
        fn f(p: *anyopaque) void {
            _ = p;
        }
    }.f;
    const cfg = MenuBarConfig{
        .app = .{
            .name = "TestApp",
            .about = MenuAction{ .zig = .{ .ctx = @ptrCast(&fired), .callback = cb } },
            .preferences = MenuAction{ .zig = .{ .ctx = @ptrCast(&fired), .callback = cb } },
        },
    };
    try std.testing.expectEqual(@as(usize, 2), countConfigActions(cfg));
}

test "menuTargetClass registers WkzMenuTarget with menuAction: selector" {
    const cls = try menuTargetClass();
    try std.testing.expect(objc.getClass("WkzMenuTarget") != null);
    try std.testing.expectEqual(objc.getClass("WkzMenuTarget").?.value, cls.value);
    try std.testing.expect(cls.msgSend(
        bool,
        "instancesRespondToSelector:",
        .{objc.sel("menuAction:").value},
    ));
}

test "menuTargetClass is idempotent" {
    const a = try menuTargetClass();
    const b = try menuTargetClass();
    try std.testing.expectEqual(a.value, b.value);
}

test "ActionEntry dispatch: zig callback fires via direct table lookup" {
    // Exercises the core dispatch logic (g_action_table indexing + callback call)
    // that impMenuAction performs at runtime. Direct AppKit NSMenuItem creation
    // requires a window server connection (headless-unsafe), so the IMP itself
    // is deferred to the manual GUI checklist — same pattern as winDelegateClass
    // in window.zig.
    var fired: bool = false;
    const callback: *const fn (*anyopaque) void = &struct {
        fn f(p: *anyopaque) void {
            @as(*bool, @ptrCast(@alignCast(p))).* = true;
        }
    }.f;

    // Temporarily set g_action_table to a single zig entry.
    var entries = [_]ActionEntry{
        .{ .zig = .{ .ctx = @ptrCast(&fired), .callback = callback } },
    };
    g_action_table = &entries;
    defer g_action_table = &.{}; // restore after test

    // Create a WkzMenuTarget instance and a fake NSMenuItem-like object with tag=0.
    // We can test dispatch directly by simulating what the IMP does:
    // read tag 0 from g_action_table and call the zig callback.
    const entry = &g_action_table[0];
    switch (entry.*) {
        .zig => |z| z.callback(z.ctx),
        .bridge => unreachable,
    }
    try std.testing.expect(fired);
}

test "MenuAction.zig callback has exact type *const fn(*anyopaque) void" {
    const ZigVariant = @FieldType(@FieldType(MenuAction, "zig"), "callback");
    try std.testing.expectEqual(*const fn (*anyopaque) void, ZigVariant);
}

test "AppMenuConfig default-initialises with only name required" {
    const cfg = AppMenuConfig{ .name = "TestApp" };
    try std.testing.expect(cfg.about == null);
    try std.testing.expect(cfg.check_for_updates == null);
    try std.testing.expect(cfg.preferences == null);
    try std.testing.expectEqual(@as(usize, 0), cfg.extra_items.len);
}

test "MenuBarConfig standard flags default to false" {
    const cfg = MenuBarConfig{ .app = .{ .name = "TestApp" } };
    try std.testing.expect(!cfg.standard_edit_menu);
    try std.testing.expect(!cfg.standard_window_menu);
    try std.testing.expectEqual(@as(usize, 0), cfg.menus.len);
}

test "MenuItem.submenu holds a slice of MenuItem (recursive type)" {
    // Verify the type compiles and the slice is zero-length by default.
    const sub = MenuItem{ .submenu = .{ .title = "Sub", .items = &.{} } };
    try std.testing.expectEqual(@as(usize, 0), sub.submenu.items.len);
}

test {
    std.testing.refAllDecls(@This());
}
