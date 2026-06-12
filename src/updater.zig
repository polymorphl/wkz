const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc");
const c = @cImport({
    @cInclude("mach-o/dyld.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("sys/stat.h");
    @cInclude("crt_externs.h");
});
const Bridge = @import("bridge.zig").Bridge;

pub const Error = error{
    ManifestFetchFailed,
    ManifestParseFailed,
    PlatformNotFound,
    DownloadFailed,
    VerifyFailed,
    InstallFailed,
};

pub const ManifestSource = union(enum) {
    url: []const u8,
    file: []const u8,
};

pub const UpdaterConfig = struct {
    manifest_source: ManifestSource,
    current_version: []const u8,
    /// ed25519 public key (32 bytes). null = signature verification disabled.
    public_key: ?[32]u8 = null,
};

pub const UpdateInfo = struct {
    version: []const u8,
    notes: []const u8,
    download_url: []const u8,
    sha256: []const u8,
    signature: ?[]const u8,
};

pub const PendingUpdate = struct {
    tmp_path: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PendingUpdate) void {
        self.allocator.free(self.tmp_path);
    }
};

/// Returned by `Updater.check`. Owns the arena containing UpdateInfo strings.
/// Call `deinit()` when done reading the info.
pub const CheckedUpdate = struct {
    arena: std.heap.ArenaAllocator,
    info: UpdateInfo,

    pub fn deinit(self: *CheckedUpdate) void {
        self.arena.deinit();
    }
};

pub const Updater = struct {
    allocator: std.mem.Allocator,
    config: UpdaterConfig,

    pub fn init(allocator: std.mem.Allocator, config: UpdaterConfig) Updater {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(_: *Updater) void {
        // Tasks 4+ may add allocated fields here.
    }

    /// Check for an available update.
    ///
    /// Ownership: returns a `CheckedUpdate` that owns the arena backing all
    /// `UpdateInfo` string slices. The caller must call `checked.deinit()` when
    /// done. Returns `null` (arena freed) when the current version is up to date.
    ///
    /// Currently only `.file` manifest sources are supported.
    /// `.url` sources return `error.ManifestFetchFailed` (Task 4).
    pub fn check(self: *Updater) !?CheckedUpdate {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();

        const json: []u8 = switch (self.config.manifest_source) {
            .file => |path| blk: {
                // Zig 0.16: std.fs.openFileAbsolute and File.readToEndAlloc
                // were removed. Use std.Io.Dir.openFileAbsolute (Dir.zig:581)
                // and File.readPositionalAll (File.zig:576) instead.
                const io = std.Io.Threaded.global_single_threaded.io();
                const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch
                    return error.ManifestFetchFailed;
                defer file.close(io);
                const file_len = file.length(io) catch return error.ManifestFetchFailed;
                if (file_len > 1 * 1024 * 1024) return error.ManifestFetchFailed;
                const buf = arena.allocator().alloc(u8, @intCast(file_len)) catch
                    return error.ManifestFetchFailed;
                const n = file.readPositionalAll(io, buf, 0) catch
                    return error.ManifestFetchFailed;
                break :blk buf[0..n];
            },
            .url => |url| blk: {
                const data = nsDataDownload(arena.allocator(), url) catch
                    return error.ManifestFetchFailed;
                break :blk data;
            },
        };

        const maybe_info = try parseManifest(arena.allocator(), json, self.config.current_version);
        if (maybe_info == null) {
            arena.deinit();
            return null;
        }
        return CheckedUpdate{ .arena = arena, .info = maybe_info.? };
    }

    /// Must be called from the main thread (ObjC Foundation).
    pub fn download(self: *Updater, info: UpdateInfo) !PendingUpdate {
        const data = try nsDataDownload(self.allocator, info.download_url);
        defer self.allocator.free(data);

        try verifySha256(data, info.sha256);

        if (self.config.public_key) |pubkey| {
            const sig_b64 = info.signature orelse return error.VerifyFailed;
            const sig_bytes = try decodeBase64Sig(self.allocator, sig_b64);
            try verifyEd25519(data, sig_bytes, pubkey);
        } else if (info.signature != null) {
            return error.VerifyFailed;
        }

        const tmp_path = try std.fmt.allocPrint(
            self.allocator,
            "/tmp/wkz-update-{s}",
            .{info.version},
        );
        errdefer self.allocator.free(tmp_path);

        const t = std.Io.Threaded.global_single_threaded;
        const io = t.io();
        const tmp_file = std.Io.Dir.createFileAbsolute(
            io,
            tmp_path,
            .{ .permissions = std.Io.File.Permissions.executable_file },
        ) catch return error.DownloadFailed;
        defer tmp_file.close(io);

        tmp_file.writeStreamingAll(io, data) catch return error.DownloadFailed;

        return PendingUpdate{ .tmp_path = tmp_path, .allocator = self.allocator };
    }

    /// Atomically replace the running binary and restart the process.
    /// Never returns on success (execv replaces the process image).
    /// Must be called from the main thread.
    pub fn install(self: *Updater, pending: PendingUpdate) !void {
        var self_buf: [4096:0]u8 = undefined;
        var self_buf_size: u32 = self_buf.len;
        if (c._NSGetExecutablePath(&self_buf, &self_buf_size) != 0) {
            return error.InstallFailed;
        }
        const self_path = std.mem.span(@as([*:0]const u8, &self_buf));

        const tmp_path_z = try self.allocator.dupeZ(u8, pending.tmp_path);
        defer self.allocator.free(tmp_path_z);

        const self_path_z = try self.allocator.dupeZ(u8, self_path);
        defer self.allocator.free(self_path_z);

        if (c.chmod(tmp_path_z.ptr, 0o755) != 0) return error.InstallFailed;
        if (c.rename(tmp_path_z.ptr, self_path_z.ptr) != 0) return error.InstallFailed;

        // Obtain the current process argv via macOS crt_externs; these are the
        // original null-terminated C strings — no allocation needed.
        const argv_ptr = c._NSGetArgv() orelse return error.InstallFailed;
        _ = c.execv(self_path_z.ptr, argv_ptr.*);
        return error.InstallFailed;
    }
};

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Returns the platform key for the current target, e.g. "darwin-aarch64".
fn platformKey() []const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "darwin-aarch64",
        .x86_64 => "darwin-x86_64",
        else => @compileError("unsupported platform for updater"),
    };
}

/// Parse the JSON manifest and return UpdateInfo for the current platform,
/// or null if the current version is already up to date.
///
/// Ownership: all returned slices borrow from `arena`; the caller must keep
/// the arena alive for as long as the returned `UpdateInfo` is used.
fn parseManifest(arena: std.mem.Allocator, json: []const u8, current_version: []const u8) !?UpdateInfo {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch
        return error.ManifestParseFailed;
    if (root != .object) return error.ManifestParseFailed;

    const version_val = root.object.get("version") orelse return error.ManifestParseFailed;
    if (version_val != .string) return error.ManifestParseFailed;
    const manifest_version_str = version_val.string;

    const notes_str: []const u8 = blk: {
        if (root.object.get("notes")) |v| {
            if (v == .string) break :blk v.string;
        }
        break :blk "";
    };

    const current = std.SemanticVersion.parse(current_version) catch return error.ManifestParseFailed;
    const manifest_ver = std.SemanticVersion.parse(manifest_version_str) catch return error.ManifestParseFailed;
    if (manifest_ver.order(current) != .gt) return null;

    const platforms_val = root.object.get("platforms") orelse return error.ManifestParseFailed;
    if (platforms_val != .object) return error.ManifestParseFailed;

    const key = platformKey();
    const platform_val = platforms_val.object.get(key) orelse return error.ManifestParseFailed;
    if (platform_val != .object) return error.ManifestParseFailed;

    const url_val = platform_val.object.get("url") orelse return error.ManifestParseFailed;
    if (url_val != .string) return error.ManifestParseFailed;

    const sha256_val = platform_val.object.get("sha256") orelse return error.ManifestParseFailed;
    if (sha256_val != .string) return error.ManifestParseFailed;

    const signature: ?[]const u8 = blk: {
        const sig_val = platform_val.object.get("signature") orelse break :blk null;
        if (sig_val == .null) break :blk null;
        if (sig_val != .string) return error.ManifestParseFailed;
        break :blk sig_val.string;
    };

    return UpdateInfo{
        .version = manifest_version_str,
        .notes = notes_str,
        .download_url = url_val.string,
        .sha256 = sha256_val.string,
        .signature = signature,
    };
}

/// Verify data matches expected_hex (64-char lowercase hex SHA-256).
fn verifySha256(data: []const u8, expected_hex: []const u8) error{VerifyFailed}!void {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    var expected_bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected_bytes, expected_hex) catch return error.VerifyFailed;

    if (!std.mem.eql(u8, &digest, &expected_bytes)) return error.VerifyFailed;
}

/// Verify ed25519 signature. sig_bytes: 64 raw bytes. pubkey_bytes: 32 bytes.
fn verifyEd25519(
    data: []const u8,
    sig_bytes: [64]u8,
    pubkey_bytes: [32]u8,
) error{VerifyFailed}!void {
    const Ed25519 = std.crypto.sign.Ed25519;
    const sig = Ed25519.Signature.fromBytes(sig_bytes);
    const pk = Ed25519.PublicKey.fromBytes(pubkey_bytes) catch return error.VerifyFailed;
    sig.verify(data, pk) catch return error.VerifyFailed;
}

/// Must be called from the main thread (ObjC Foundation).
/// Download URL bytes using macOS NSData (synchronous). Caller owns result.
fn nsDataDownload(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    const NSData = objc.getClass("NSData") orelse return error.DownloadFailed;
    const NSURL = objc.getClass("NSURL") orelse return error.DownloadFailed;
    const NSString = objc.getClass("NSString") orelse return error.DownloadFailed;

    const url_z = try allocator.dupeZ(u8, url);
    defer allocator.free(url_z);

    const ns_str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{url_z.ptr});
    const ns_url = NSURL.msgSend(objc.Object, "URLWithString:", .{ns_str});

    const ns_data_raw = NSData.msgSend(objc.Object, "dataWithContentsOfURL:", .{ns_url});
    if (ns_data_raw.value == null) return error.DownloadFailed;
    const ns_data = ns_data_raw.retain();
    defer ns_data.release();

    const bytes_ptr = ns_data.msgSend(?[*]const u8, "bytes", .{}) orelse
        return error.DownloadFailed;
    const length = ns_data.msgSend(usize, "length", .{});

    return allocator.dupe(u8, bytes_ptr[0..length]);
}

/// Decode base64-encoded ed25519 signature to 64 raw bytes.
fn decodeBase64Sig(allocator: std.mem.Allocator, b64: []const u8) ![64]u8 {
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(b64) catch
        return error.VerifyFailed;
    if (decoded_len != 64) return error.VerifyFailed;

    const decoded = allocator.alloc(u8, decoded_len) catch return error.VerifyFailed;
    defer allocator.free(decoded);

    std.base64.standard.Decoder.decode(decoded, b64) catch return error.VerifyFailed;

    var buf: [64]u8 = undefined;
    @memcpy(&buf, decoded);
    return buf;
}

// ── Bridge integration ────────────────────────────────────────────────────────

/// Register the updater's three bridge handlers and store `self` as bridge context.
/// Call once at app startup after bridge.init() and bridge.attach().
pub fn registerBridgeHandlers(self: *Updater, bridge_ptr: *Bridge) !void {
    bridge_ptr.context = @ptrCast(self);
    try bridge_ptr.registerHandler("updater.check", handleCheck);
    try bridge_ptr.registerHandler("updater.download", handleDownload);
    try bridge_ptr.registerHandler("updater.install", handleInstall);
}

pub fn handleCheck(bridge_ptr: *Bridge, _: std.json.Value, id: ?i64) void {
    const self: *Updater = @ptrCast(@alignCast(bridge_ptr.context.?));
    var maybe_checked = self.check() catch |err| {
        emitError(bridge_ptr, self.allocator, "check_failed", @errorName(err));
        if (id) |i| bridge_ptr.resolve(i, "null") catch {};
        return;
    };
    if (maybe_checked) |*checked| {
        defer checked.deinit();
        const payload = std.fmt.allocPrint(
            self.allocator,
            "{{\"version\":\"{s}\",\"notes\":\"{s}\"}}",
            .{ checked.info.version, checked.info.notes },
        ) catch {
            if (id) |i| bridge_ptr.resolve(i, "null") catch {};
            return;
        };
        defer self.allocator.free(payload);
        emitEvent(bridge_ptr, self.allocator, "update.available", payload);
        if (id) |i| bridge_ptr.resolve(i, payload) catch {};
    } else {
        if (id) |i| bridge_ptr.resolve(i, "null") catch {};
    }
}

pub fn handleDownload(bridge_ptr: *Bridge, _: std.json.Value, id: ?i64) void {
    const self: *Updater = @ptrCast(@alignCast(bridge_ptr.context.?));
    const maybe_checked = self.check() catch |err| {
        emitError(bridge_ptr, self.allocator, "download_failed", @errorName(err));
        if (id) |i| bridge_ptr.resolve(i, "null") catch {};
        return;
    };
    var checked = maybe_checked orelse {
        emitError(bridge_ptr, self.allocator, "download_failed", "AlreadyUpToDate");
        if (id) |i| bridge_ptr.resolve(i, "null") catch {};
        return;
    };
    defer checked.deinit();

    emitEvent(bridge_ptr, self.allocator, "update.progress", "{\"percent\":0}");
    var pending = self.download(checked.info) catch |err| {
        emitError(bridge_ptr, self.allocator, "download_failed", @errorName(err));
        if (id) |i| bridge_ptr.resolve(i, "null") catch {};
        return;
    };
    defer pending.deinit();

    emitEvent(bridge_ptr, self.allocator, "update.progress", "{\"percent\":100}");
    emitEvent(bridge_ptr, self.allocator, "update.ready", "{}");
    if (id) |i| bridge_ptr.resolve(i, "null") catch {};
}

pub fn handleInstall(bridge_ptr: *Bridge, _: std.json.Value, id: ?i64) void {
    _ = id;
    const self: *Updater = @ptrCast(@alignCast(bridge_ptr.context.?));
    // Re-check to reconstruct the version string for the tmp path.
    // Known limitation: requires a network/file round-trip. A production impl
    // would cache UpdateInfo between download and install on the Updater struct.
    const maybe_checked = self.check() catch return;
    var checked = maybe_checked orelse return;
    defer checked.deinit();

    const tmp_path = std.fmt.allocPrint(
        self.allocator,
        "/tmp/wkz-update-{s}",
        .{checked.info.version},
    ) catch return;
    const pending = PendingUpdate{ .tmp_path = tmp_path, .allocator = self.allocator };
    // Note: pending.deinit() not called here — install() calls execv which
    // replaces the process on success. On error, tmp_path is leaked (acceptable
    // for install failure; process is in bad state anyway).
    self.install(pending) catch |err| {
        emitError(bridge_ptr, self.allocator, "install_failed", @errorName(err));
    };
    // install() only returns on error (execv replaced the process on success)
}

// ── Private event helpers ─────────────────────────────────────────────────────

fn emitEvent(
    bridge_ptr: *Bridge,
    allocator: std.mem.Allocator,
    event_type: []const u8,
    payload_json: []const u8,
) void {
    const js = std.fmt.allocPrintSentinel(
        allocator,
        "window.__wkz_event({{\"type\":\"{s}\",\"payload\":{s}}})",
        .{ event_type, payload_json },
        0,
    ) catch return;
    defer allocator.free(js);
    bridge_ptr.evaluate(js);
}

fn emitError(
    bridge_ptr: *Bridge,
    allocator: std.mem.Allocator,
    code: []const u8,
    message: []const u8,
) void {
    const payload = std.fmt.allocPrint(
        allocator,
        "{{\"code\":\"{s}\",\"message\":\"{s}\"}}",
        .{ code, message },
    ) catch return;
    defer allocator.free(payload);
    emitEvent(bridge_ptr, allocator, "update.error", payload);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "platformKey returns expected string" {
    const key = platformKey();
    const expected = switch (builtin.cpu.arch) {
        .aarch64 => "darwin-aarch64",
        .x86_64 => "darwin-x86_64",
        else => unreachable,
    };
    try std.testing.expectEqualStrings(expected, key);
}

test "parseManifest: newer version returns UpdateInfo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const manifest =
        \\{
        \\  "version": "1.2.0",
        \\  "pub_date": "2026-06-12T10:00:00Z",
        \\  "notes": "Bug fixes.",
        \\  "platforms": {
        \\    "darwin-aarch64": {
        \\      "url": "https://example.com/app-aarch64",
        \\      "sha256": "abc123",
        \\      "signature": null
        \\    },
        \\    "darwin-x86_64": {
        \\      "url": "https://example.com/app-x86_64",
        \\      "sha256": "def456",
        \\      "signature": null
        \\    }
        \\  }
        \\}
    ;

    const result = try parseManifest(arena.allocator(), manifest, "1.0.0");
    const info = result orelse return error.TestExpectedUpdate;
    try std.testing.expectEqualStrings("1.2.0", info.version);
    try std.testing.expectEqualStrings("Bug fixes.", info.notes);
    try std.testing.expect(info.signature == null);
}

test "parseManifest: same version returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const manifest =
        \\{
        \\  "version": "1.0.0",
        \\  "pub_date": "2026-06-12T10:00:00Z",
        \\  "notes": "No change.",
        \\  "platforms": {
        \\    "darwin-aarch64": {
        \\      "url": "https://example.com/app-aarch64",
        \\      "sha256": "abc123",
        \\      "signature": null
        \\    },
        \\    "darwin-x86_64": {
        \\      "url": "https://example.com/app-x86_64",
        \\      "sha256": "def456",
        \\      "signature": null
        \\    }
        \\  }
        \\}
    ;

    const result = try parseManifest(arena.allocator(), manifest, "1.0.0");
    try std.testing.expect(result == null);
}

test "parseManifest: older version returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const manifest =
        \\{
        \\  "version": "0.9.0",
        \\  "pub_date": "2026-06-12T10:00:00Z",
        \\  "notes": "Old.",
        \\  "platforms": {
        \\    "darwin-aarch64": {
        \\      "url": "https://example.com/app-aarch64",
        \\      "sha256": "abc123",
        \\      "signature": null
        \\    },
        \\    "darwin-x86_64": {
        \\      "url": "https://example.com/app-x86_64",
        \\      "sha256": "def456",
        \\      "signature": null
        \\    }
        \\  }
        \\}
    ;

    const result = try parseManifest(arena.allocator(), manifest, "1.0.0");
    try std.testing.expect(result == null);
}

test "parseManifest: missing platform returns ManifestParseFailed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const manifest =
        \\{
        \\  "version": "2.0.0",
        \\  "pub_date": "2026-06-12T10:00:00Z",
        \\  "notes": "Future.",
        \\  "platforms": {}
        \\}
    ;

    const result = parseManifest(arena.allocator(), manifest, "1.0.0");
    try std.testing.expectError(error.ManifestParseFailed, result);
}

test "verifySha256: correct hash passes" {
    const data = "hello wkz";
    // echo -n "hello wkz" | sha256sum
    const expected_hex = "998133c210a25b600891bac02e8d23ab789148a36bc94c442469abd58340cab2";
    try verifySha256(data, expected_hex);
}

test "verifySha256: wrong hash returns VerifyFailed" {
    const data = "hello wkz";
    const wrong_hex = "0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expectError(error.VerifyFailed, verifySha256(data, wrong_hex));
}

test "verifyEd25519: valid signature passes" {
    const Ed25519 = std.crypto.sign.Ed25519;
    const seed: [Ed25519.KeyPair.seed_length]u8 = [_]u8{0x42} ** Ed25519.KeyPair.seed_length;
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const message = "test binary contents";
    const sig = try kp.sign(message, null);
    try verifyEd25519(message, sig.toBytes(), kp.public_key.toBytes());
}

test "verifyEd25519: tampered message returns VerifyFailed" {
    const Ed25519 = std.crypto.sign.Ed25519;
    const seed: [Ed25519.KeyPair.seed_length]u8 = [_]u8{0x42} ** Ed25519.KeyPair.seed_length;
    const kp = try Ed25519.KeyPair.generateDeterministic(seed);
    const message = "test binary contents";
    const sig = try kp.sign(message, null);
    try std.testing.expectError(
        error.VerifyFailed,
        verifyEd25519("tampered contents", sig.toBytes(), kp.public_key.toBytes()),
    );
}
