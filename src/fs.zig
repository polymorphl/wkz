const std = @import("std");
const objc = @import("objc");
const Bridge = @import("bridge.zig").Bridge;

const log = std.log.scoped(.wkz_fs);

const max_file_size: usize = 10 * 1024 * 1024; // 10 MiB

pub const Fs = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Fs {
        return .{ .allocator = allocator };
    }

    /// Register all `fs.*` bridge handlers on `bridge`.
    ///
    /// Ownership: borrows `bridge` for the duration of the call only; sets
    /// `bridge.context` to a type-erased pointer to `self`. The caller must
    /// ensure `self` outlives any JS↔Zig message that could arrive after this
    /// call returns.
    pub fn registerBridgeHandlers(self: *Fs, bridge: *Bridge) !void {
        bridge.context = @ptrCast(self);
        try bridge.registerHandler("fs.openFile", handleOpenFile);
        try bridge.registerHandler("fs.readText", handleReadText);
        try bridge.registerHandler("fs.readBinary", handleReadBinary);
        try bridge.registerHandler("fs.writeText", handleWriteText);
    }
};

fn handleOpenFile(bridge: *Bridge, _: std.json.Value, id: ?i64) void {
    if (id) |i| bridge.resolve(i, "null") catch {};
}

fn handleReadText(bridge: *Bridge, _: std.json.Value, id: ?i64) void {
    if (id) |i| bridge.resolve(i, "null") catch {};
}

fn handleReadBinary(bridge: *Bridge, _: std.json.Value, id: ?i64) void {
    if (id) |i| bridge.resolve(i, "null") catch {};
}

fn handleWriteText(bridge: *Bridge, _: std.json.Value, id: ?i64) void {
    if (id) |i| bridge.resolve(i, "null") catch {};
}
