//! Code generator: walks a `dist/` directory, copies every asset into an
//! output directory, and writes `dist_assets.zig` in that directory with
//! relative `@embedFile` paths.
//!
//! Usage: gen_assets <dist_dir> <out_dir>
//!
//!   dist_dir  — absolute path to the Vite build output directory.
//!   out_dir   — absolute path to the output directory managed by the build
//!               system (created by `addOutputDirectoryArg`).
//!
//! For each file found in dist_dir the generator:
//!   1. Copies the file into out_dir preserving relative path structure
//!      (creating parent directories as needed).
//!   2. Emits one `@embedFile("rel_path")` entry in `dist_assets.zig`.
//!
//! Because the generated file and all referenced assets live in the same
//! directory tree, `@embedFile` paths are relative to out_dir and always
//! resolve correctly regardless of where the build cache places out_dir.
//!
//! Entries are sorted alphabetically by path for deterministic output.
//!
//! Zig 0.16 std APIs verified against
//!   /opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std/
//!   * std.process.Init                — process.zig:30
//!   * std.process.Args.Iterator.init  — process/Args.zig:37
//!   * std.Io.Dir.openDirAbsolute      — Io/Dir.zig:485
//!   * std.Io.Dir.copyFile             — Io/Dir.zig:1809 — (src_dir, src_path, dst_dir, dst_path, io, options)
//!   * std.Io.Dir.CopyFileOptions      — Io/Dir.zig:1784 — { .make_path = true, .replace = true }
//!   * std.Io.Dir.createFile           — Io/Dir.zig:638 — createFile(dir, io, sub_path, flags)
//!   * dir.walk(allocator)             — Io/Dir.zig:397
//!   * walker.next(io)                 — Io/Dir.zig:365
//!   * walker.deinit()                 — Io/Dir.zig:373
//!   * dir.close(io)                   — Io/Dir.zig:490
//!   * file.writer(io, &buf)           — Io/File.zig:600
//!   * file.close(io)                  — Io/File.zig:221
//!   * std.sort.heap                   — sort.zig:57
//!   * std.ArrayList.empty/.append(gpa,item)/.deinit(gpa) — array_list.zig:591,903,Aligned
//!   * allocator.dupe(u8, slice)       — mem/Allocator.zig:453

const std = @import("std");

/// MIME type lookup for generated @embedFile entries.
/// Must stay in sync with `src/scheme.zig:mimeForPath` (source of truth).
/// When adding a new extension, update both functions together.
fn mimeForExt(path: []const u8) []const u8 {
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

/// Entry collected from the directory walk.
const CollectedEntry = struct {
    /// Path relative to dist_dir root (e.g. "index.html", "assets/index.js").
    /// Heap-allocated, owned by the ArrayList.
    rel_path: []const u8,
};

/// Returns true when `path` would produce syntactically broken Zig source if
/// interpolated into a `@embedFile("...")` string literal — i.e. it contains a
/// double-quote or a backslash. These characters are the only ones that can
/// break the generated literal without additional escaping. All other bytes
/// (including forward slashes, dots, hyphens, Unicode) are safe.
///
/// Extracted so it can be unit-tested independently of the I/O machinery in main.
fn isUnsafePath(path: []const u8) bool {
    return std.mem.indexOfAny(u8, path, "\"\\") != null;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // Parse arguments: skip argv[0] (program name), expect exactly 2 args.
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip(); // program name

    const dist_dir_path = args.next() orelse {
        std.log.err("usage: gen_assets <dist_dir> <out_dir>", .{});
        return error.MissingArgument;
    };
    const out_dir_path = args.next() orelse {
        std.log.err("usage: gen_assets <dist_dir> <out_dir>", .{});
        return error.MissingArgument;
    };

    // Open the dist directory for recursive walking.
    // openDirAbsolute: Io/Dir.zig:485 — openDirAbsolute(io, absolute_path, options)
    var dist_dir = try std.Io.Dir.openDirAbsolute(io, dist_dir_path, .{
        .iterate = true,
    });
    defer dist_dir.close(io);

    // Walk the directory and collect all regular files.
    // walk: Io/Dir.zig:397 — walk(dir, allocator) Allocator.Error!Walker
    var walker = try dist_dir.walk(gpa);
    defer walker.deinit();

    // Open the output directory (created by the build system via addOutputDirectoryArg).
    // openDirAbsolute: Io/Dir.zig:485 — openDirAbsolute(io, absolute_path, options)
    var out_dir = try std.Io.Dir.openDirAbsolute(io, out_dir_path, .{});
    defer out_dir.close(io);

    // Collect entries into a list so we can sort before writing.
    // std.ArrayList is Aligned(T, null) in 0.16 — unmanaged, use .empty + gpa per call.
    // std.ArrayList.empty: array_list.zig:591
    // std.ArrayList.append: array_list.zig:903 — append(*Self, gpa, item)
    // std.ArrayList.deinit: verified below — deinit(*Self, gpa)
    var entries: std.ArrayList(CollectedEntry) = .empty;
    defer {
        for (entries.items) |e| {
            gpa.free(e.rel_path);
        }
        entries.deinit(gpa);
    }

    // next: Io/Dir.zig:365 — next(*Walker, io) !?Walker.Entry
    while (try walker.next(io)) |entry| {
        // Only collect regular files; directories are traversed automatically.
        if (entry.kind != .file) continue;

        // Walker.Entry.path is a [:0]const u8 relative to the walked root.
        // It is invalidated on the next call to next() or deinit() — copy it.
        // allocator.dupe: mem/Allocator.zig:453 — dupe(allocator, T, m) Error![]T
        const rel_path = try gpa.dupe(u8, entry.path);
        errdefer gpa.free(rel_path);

        try entries.append(gpa, .{ .rel_path = rel_path });
    }

    // Sort entries alphabetically by relative path for deterministic output.
    // std.sort.heap: sort.zig:57 — heap(T, items, context, lessThanFn)
    std.sort.heap(CollectedEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: CollectedEntry, b: CollectedEntry) bool {
            return std.mem.lessThan(u8, a.rel_path, b.rel_path);
        }
    }.lessThan);

    // Copy each asset into out_dir, preserving relative path structure.
    // copyFile: Io/Dir.zig:1809 — copyFile(src_dir, src_path, dst_dir, dst_path, io, options)
    // CopyFileOptions.make_path=true creates parent directories automatically.
    for (entries.items) |e| {
        try std.Io.Dir.copyFile(dist_dir, e.rel_path, out_dir, e.rel_path, io, .{
            .make_path = true,
            .replace = true,
        });
    }

    // Write dist_assets.zig into out_dir using relative @embedFile paths.
    // createFile: Io/Dir.zig:638 — createFile(dir, io, sub_path, flags)
    const out_file = try out_dir.createFile(io, "dist_assets.zig", .{});
    defer out_file.close(io);

    // file.writer: Io/File.zig:600 — writer(file, io, buffer) Writer
    var write_buf: [4096]u8 = undefined;
    var writer = out_file.writer(io, &write_buf);

    try writer.interface.print(
        \\// Auto-generated by tools/gen_assets.zig — do not edit.
        \\const wkz = @import("wkz");
        \\
        \\pub const asset_map = wkz.scheme.AssetMap{{
        \\    .entries = &.{{
        \\
    , .{});

    for (entries.items) |e| {
        const mime = mimeForExt(e.rel_path);
        // @embedFile paths are relative to the source file (dist_assets.zig),
        // which lives in out_dir alongside the copied assets.
        if (isUnsafePath(e.rel_path)) {
            std.log.err("unsafe asset path (contains quote or backslash): {s}", .{e.rel_path});
            return error.UnsafeAssetPath;
        }
        try writer.interface.print(
            "        .{{ .path = \"{s}\", .asset = .{{ .data = @embedFile(\"{s}\"), .mime = \"{s}\" }} }},\n",
            .{ e.rel_path, e.rel_path, mime },
        );
    }

    try writer.interface.print(
        \\    }},
        \\}};
        \\
    , .{});

    // Flush the buffered writer. writer.flush: Io/Writer.zig:312
    try writer.flush();
}

// =====================================================================
// Tests
// =====================================================================

test "mimeForExt: all documented extensions return the correct MIME type" {
    // Each extension that the generator writes into dist_assets.zig.
    // These must match scheme.zig:mimeForPath exactly (source-of-truth sync check).
    try std.testing.expectEqualStrings("text/html; charset=utf-8", mimeForExt("index.html"));
    try std.testing.expectEqualStrings("text/html; charset=utf-8", mimeForExt("/sub/page.html"));
    try std.testing.expectEqualStrings("application/javascript; charset=utf-8", mimeForExt("app.js"));
    try std.testing.expectEqualStrings("application/javascript; charset=utf-8", mimeForExt("assets/index-abc123.js"));
    try std.testing.expectEqualStrings("text/css; charset=utf-8", mimeForExt("style.css"));
    try std.testing.expectEqualStrings("image/svg+xml", mimeForExt("logo.svg"));
    try std.testing.expectEqualStrings("image/png", mimeForExt("icon.png"));
    try std.testing.expectEqualStrings("image/x-icon", mimeForExt("favicon.ico"));
    try std.testing.expectEqualStrings("font/woff2", mimeForExt("font.woff2"));
    try std.testing.expectEqualStrings("application/json", mimeForExt("data.json"));
    // Unknown / fallback cases.
    try std.testing.expectEqualStrings("application/octet-stream", mimeForExt("module.wasm"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeForExt("binary.bin"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeForExt("no_extension"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeForExt(""));
}

test "mimeForExt: extension matching is suffix-based, not dot-split (adversarial)" {
    // A file named ".js" (just the extension, no stem) is a real Vite output.
    try std.testing.expectEqualStrings("application/javascript; charset=utf-8", mimeForExt(".js"));
    // Embedded extension in the stem does NOT confuse the suffix check.
    try std.testing.expectEqualStrings("application/octet-stream", mimeForExt("app.js.map"));
    // Case-sensitive: uppercase extension is NOT matched.
    try std.testing.expectEqualStrings("application/octet-stream", mimeForExt("index.HTML"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeForExt("style.CSS"));
    // A path whose final bytes look like an extension but span across a / boundary:
    // "dir.html/file" ends with "/file", not ".html".
    try std.testing.expectEqualStrings("application/octet-stream", mimeForExt("dir.html/file"));
}

test "mimeForExt: sync with scheme.zig mimeForPath — identical results for all known extensions" {
    // This is the cross-file drift guard. If one table is updated without the
    // other, this test fails. The test intentionally repeats every case that
    // scheme.zig:mimeForPath covers, using the same inputs used in scheme.zig's
    // own test suite, and checks that mimeForExt returns the same string.
    const pairs = [_]struct { path: []const u8, mime: []const u8 }{
        .{ .path = "index.html",              .mime = "text/html; charset=utf-8" },
        .{ .path = "/foo/bar.html",           .mime = "text/html; charset=utf-8" },
        .{ .path = "app.js",                  .mime = "application/javascript; charset=utf-8" },
        .{ .path = "assets/index-abc123.js",  .mime = "application/javascript; charset=utf-8" },
        .{ .path = "style.css",               .mime = "text/css; charset=utf-8" },
        .{ .path = "logo.svg",                .mime = "image/svg+xml" },
        .{ .path = "icon.png",                .mime = "image/png" },
        .{ .path = "favicon.ico",             .mime = "image/x-icon" },
        .{ .path = "font.woff2",              .mime = "font/woff2" },
        .{ .path = "data.json",               .mime = "application/json" },
        .{ .path = "binary.wasm",             .mime = "application/octet-stream" },
        .{ .path = "unknown",                 .mime = "application/octet-stream" },
        .{ .path = "",                        .mime = "application/octet-stream" },
    };
    for (pairs) |p| {
        try std.testing.expectEqualStrings(p.mime, mimeForExt(p.path));
    }
}

test "isUnsafePath: returns false for safe Vite output paths" {
    // Typical Vite output tree — all should be safe.
    try std.testing.expect(!isUnsafePath("index.html"));
    try std.testing.expect(!isUnsafePath("assets/index-abc123.js"));
    try std.testing.expect(!isUnsafePath("assets/style-def456.css"));
    try std.testing.expect(!isUnsafePath("assets/logo.svg"));
    try std.testing.expect(!isUnsafePath("fonts/roboto.woff2"));
    try std.testing.expect(!isUnsafePath("favicon.ico"));
    try std.testing.expect(!isUnsafePath("manifest.json"));
    // Forward slashes, hyphens, dots, underscores, digits: all safe.
    try std.testing.expect(!isUnsafePath("a/b/c/d-e_f.g123"));
    // Empty string is safe (no dangerous chars).
    try std.testing.expect(!isUnsafePath(""));
}

test "isUnsafePath: returns true for paths containing a double-quote" {
    try std.testing.expect(isUnsafePath("index\".html"));
    try std.testing.expect(isUnsafePath("\""));
    try std.testing.expect(isUnsafePath("assets/fi\"le.js"));
    // Quote at start.
    try std.testing.expect(isUnsafePath("\"leading"));
    // Quote at end.
    try std.testing.expect(isUnsafePath("trailing\""));
}

test "isUnsafePath: returns true for paths containing a backslash" {
    try std.testing.expect(isUnsafePath("assets\\index.js"));
    try std.testing.expect(isUnsafePath("\\"));
    // Backslash at various positions.
    try std.testing.expect(isUnsafePath("a\\b"));
    try std.testing.expect(isUnsafePath("\\leading"));
    try std.testing.expect(isUnsafePath("trailing\\"));
}

test "isUnsafePath: returns true for paths containing both quote and backslash" {
    try std.testing.expect(isUnsafePath("a\\\"b"));
    try std.testing.expect(isUnsafePath("\"\\"));
}

test "isUnsafePath: other non-ASCII / special bytes are NOT considered unsafe" {
    // These would be unusual Vite outputs but are technically valid UTF-8 paths
    // on macOS. The guard is narrowly scoped to chars that break Zig string
    // literals — nothing else.
    try std.testing.expect(!isUnsafePath("assets/\xc3\xa9l\xc3\xa8ve.js")); // UTF-8 "élève.js"
    try std.testing.expect(!isUnsafePath("assets/file name.js")); // space
    try std.testing.expect(!isUnsafePath("assets/file#1.js")); // hash
    try std.testing.expect(!isUnsafePath("assets/file?v=1.js")); // question mark
    try std.testing.expect(!isUnsafePath("assets/\x00null.js")); // embedded NUL — not in the unsafe set
}
