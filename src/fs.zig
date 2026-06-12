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

    /// Register the fs bridge handlers and set bridge.context to this Fs instance.
    /// Call once at startup after bridge.attach().
    ///
    /// Security: `fs.readText`, `fs.readBinary`, and `fs.writeText` accept
    /// absolute paths directly from JS without path traversal validation.
    /// Only register these handlers in apps where the webview loads trusted
    /// local content. Do not expose them in apps loading remote URLs.
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

/// Extract the "path" string from a bridge params value.
/// Returns null if params is not an object or has no string "path" field.
fn extractPath(params: std.json.Value) ?[]const u8 {
    const obj = switch (params) {
        .object => |o| o,
        else => return null,
    };
    const val = obj.get("path") orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Read an entire file by absolute path. Caller owns the returned slice.
/// Returns error.FileTooLarge if file exceeds max_file_size.
fn readFileBytes(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const file_len = try file.length(io);
    if (file_len > max_file_size) return error.FileTooLarge;
    const buf = try allocator.alloc(u8, @intCast(file_len));
    errdefer allocator.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    if (n != file_len) return error.UnexpectedEof; // errdefer frees buf
    return buf;
}

/// Base64-encode data using standard alphabet with padding. Caller owns result.
fn encodeBase64(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(data.len);
    const buf = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(buf, data);
    return buf;
}

/// Write UTF-8 text to an absolute path, truncating if the file exists.
fn writeTextToPath(path: []const u8, content: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

/// Resolves with {"path":"/absolute/path"} when user selects a file, or "null" if cancelled.
fn handleOpenFile(bridge: *Bridge, _: std.json.Value, id: ?i64) void {
    const self: *Fs = @ptrCast(@alignCast(bridge.context.?));

    // NSOpenPanel is looked up from the ObjC runtime — same pattern as
    // NSApplication in app.zig:40 and NSMenuItem in app.zig:88.
    const NSOpenPanel = objc.getClass("NSOpenPanel") orelse {
        log.warn("fs.openFile: NSOpenPanel class not found in ObjC runtime", .{});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    };

    const panel = NSOpenPanel.msgSend(objc.Object, "openPanel", .{});
    panel.msgSend(void, "setCanChooseFiles:", .{true});
    panel.msgSend(void, "setCanChooseDirectories:", .{false});
    panel.msgSend(void, "setAllowsMultipleSelection:", .{false});

    // runModal blocks the main thread until the user dismisses the panel.
    // NSModalResponseOK = 1. NSInteger = c_long on macOS (confirmed app.zig:13).
    const response = panel.msgSend(c_long, "runModal", .{});
    if (response != 1) {
        // User cancelled.
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    }

    // panel.URLs -> NSArray -> objectAtIndex:0 -> NSURL -> path -> UTF8String.
    // NSUInteger index type = c_ulong on macOS.
    const urls = panel.msgSend(objc.Object, "URLs", .{});
    const url = urls.msgSend(objc.Object, "objectAtIndex:", .{@as(c_ulong, 0)});
    const path_nsstring = url.msgSend(objc.Object, "path", .{});
    const path_cstr = path_nsstring.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse {
        log.warn("fs.openFile: UTF8String returned null for selected URL path", .{});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    };
    const path = std.mem.span(path_cstr);

    const json = std.json.Stringify.valueAlloc(
        self.allocator,
        .{ .path = path },
        .{},
    ) catch {
        log.warn("fs.openFile: json serialization failed (OOM)", .{});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    };
    defer self.allocator.free(json);
    if (id) |i| bridge.resolve(i, json) catch {};
}

fn handleReadText(bridge: *Bridge, params: std.json.Value, id: ?i64) void {
    const self: *Fs = @ptrCast(@alignCast(bridge.context.?));
    const path = extractPath(params) orelse {
        log.warn("fs.readText: missing or non-string path param", .{});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    };
    const bytes = readFileBytes(self.allocator, path) catch |err| {
        log.warn("fs.readText: read failed path={s} err={s}", .{ path, @errorName(err) });
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    };
    defer self.allocator.free(bytes);
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        log.warn("fs.readText: file is not valid UTF-8 path={s}", .{path});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    }
    // std.json.Stringify.valueAlloc serialises []u8 as a JSON string when
    // the slice is valid UTF-8 (Stringify.zig:504-508).
    const json = std.json.Stringify.valueAlloc(
        self.allocator,
        .{ .content = bytes },
        .{},
    ) catch {
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    };
    defer self.allocator.free(json);
    if (id) |i| bridge.resolve(i, json) catch {};
}

/// Resolves with {"data":"<base64string>"} or "null" on error.
fn handleReadBinary(bridge: *Bridge, params: std.json.Value, id: ?i64) void {
    const self: *Fs = @ptrCast(@alignCast(bridge.context.?));
    const path = extractPath(params) orelse {
        log.warn("fs.readBinary: missing or non-string path param", .{});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    };
    const bytes = readFileBytes(self.allocator, path) catch |err| {
        log.warn("fs.readBinary: read failed path={s} err={s}", .{ path, @errorName(err) });
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    };
    defer self.allocator.free(bytes);
    const encoded = encodeBase64(self.allocator, bytes) catch {
        log.warn("fs.readBinary: encodeBase64 failed (OOM)", .{});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    };
    defer self.allocator.free(encoded);
    // encoded is pure base64 ASCII — always valid UTF-8, always a JSON string.
    const json = std.json.Stringify.valueAlloc(
        self.allocator,
        .{ .data = encoded },
        .{},
    ) catch {
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    };
    defer self.allocator.free(json);
    if (id) |i| bridge.resolve(i, json) catch {};
}

/// Resolves with "null" on success or error (errors are logged).
fn handleWriteText(bridge: *Bridge, params: std.json.Value, id: ?i64) void {
    const obj = switch (params) {
        .object => |o| o,
        else => {
            log.warn("fs.writeText: params must be a JSON object", .{});
            if (id) |i| bridge.resolve(i, "null") catch {};
            return;
        },
    };

    const path = switch (obj.get("path") orelse {
        log.warn("fs.writeText: missing path param", .{});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    }) {
        .string => |s| s,
        else => {
            log.warn("fs.writeText: path must be a string", .{});
            if (id) |i| bridge.resolve(i, "null") catch {};
            return;
        },
    };

    const content = switch (obj.get("content") orelse {
        log.warn("fs.writeText: missing content param", .{});
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    }) {
        .string => |s| s,
        else => {
            log.warn("fs.writeText: content must be a string", .{});
            if (id) |i| bridge.resolve(i, "null") catch {};
            return;
        },
    };

    writeTextToPath(path, content) catch |err| {
        log.warn("fs.writeText: write failed path={s} err={s}", .{ path, @errorName(err) });
        if (id) |i| bridge.resolve(i, "null") catch {};
        return;
    };
    if (id) |i| bridge.resolve(i, "null") catch {};
}

test "encodeBase64 known vector" {
    const allocator = std.testing.allocator;
    const result = try encodeBase64(allocator, "hello");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("aGVsbG8=", result);
}

test "encodeBase64 round-trips binary data" {
    const allocator = std.testing.allocator;
    const data: []const u8 = &.{ 0x00, 0x01, 0xFF, 0xFE, 0x42 };
    const encoded = try encodeBase64(allocator, data);
    defer allocator.free(encoded);

    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, encoded);
    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "readFileBytes reads a known file" {
    const allocator = std.testing.allocator;
    const path = "/tmp/wkz-fs-test-readbytes.txt";
    const expected = "hello wkz readFileBytes";

    // Write the test file using the same Zig 0.16 API.
    const io = std.Io.Threaded.global_single_threaded.io();
    const f = try std.Io.Dir.createFileAbsolute(io, path, .{});
    try f.writeStreamingAll(io, expected);
    f.close(io);

    const result = try readFileBytes(allocator, path);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(expected, result);
}

test "writeTextToPath creates and reads back a file" {
    const allocator = std.testing.allocator;
    const path = "/tmp/wkz-fs-test-write.txt";
    const content = "wkz writeTextToPath test";
    try writeTextToPath(path, content);
    const result = try readFileBytes(allocator, path);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(content, result);
}
