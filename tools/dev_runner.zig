//! dev_runner — starts the Vite dev server and exits once it is ready.
//!
//! Usage: dev_runner <frontend_dir> <pid_file>
//!
//!   frontend_dir  — directory containing `package.json` with a `dev` script
//!   pid_file      — absolute path where the bun process PID will be written
//!
//! Execution sequence:
//!   1. Spawn `bun run dev` in frontend_dir (stdout/stderr inherited — Vite
//!      output remains visible in the terminal).
//!   2. Poll ::1:5173 (IPv6) then 127.0.0.1:5173 (IPv4) every 200 ms, up to 150 attempts (30 s).
//!      On timeout: kill bun, print error, exit(1).
//!   3. Write bun's PID as a decimal string to pid_file.
//!   4. Exit with code 0.  Bun continues running as an orphan in the same
//!      process group as the caller (zig build), so Ctrl+C still kills it.
//!
//! The caller (examples/*/build.zig) is responsible for:
//!   a. Running the app binary DIRECTLY as the next build step so that it is
//!      a direct child of the zig build process (required for NSApp activation).
//!   b. Running a cleanup step after the app exits to kill bun via the PID file.
//!
//! SIGINT: kill bun, exit(130).
//!
//! Zig 0.16 std APIs verified against
//!   /opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std/
//!   * std.process.Init                            — process.zig:30
//!   * std.process.Args.Iterator.init              — process/Args.zig:37
//!   * std.process.spawn(io, SpawnOptions)         — process.zig:442
//!   * std.process.SpawnOptions{.argv,.cwd,.stdin,.stdout,.stderr} — process.zig:360
//!   * std.process.Child.Cwd.path                  — process/Child.zig:109
//!   * std.process.Child.kill(*child, io)          — process/Child.zig:118
//!   * std.process.Child.Id (posix.pid_t on !windows) — process/Child.zig:16
//!   * std.Io.net.IpAddress.connect(*addr,io,opts) — Io/net.zig:339
//!   * std.Io.net.IpAddress.ConnectOptions{.mode}  — Io/net.zig:332
//!   * std.Io.net.Ip4Address.loopback(port)        — Io/net.zig:349
//!   * std.Io.net.Stream.close(*stream, io)        — Io/net.zig:1248
//!   * std.Io.sleep(io, duration, clock)           — Io.zig:2397
//!   * std.Io.Duration.fromMilliseconds(x)         — Io.zig:982
//!   * std.Io.Clock.real                           — Io.zig:738 (enum value)
//!   * std.Io.Dir.cwd()                            — Io/Dir.zig:88
//!   * std.Io.Dir.writeFile(dir, io, opts)         — Io/Dir.zig:658
//!   * std.Io.Dir.WriteFileOptions{.sub_path,.data} — Io/Dir.zig:646
//!   * std.posix.sigaction(sig, act, oact)         — posix.zig:942
//!   * std.posix.Sigaction{.handler,.mask,.flags}  — c.zig:3218 (macOS branch)
//!   * std.posix.sigemptyset()                     — posix.zig:899
//!   * std.posix.kill(pid, sig)                    — posix.zig:378
//!   * std.posix.SIG.INT                           — c.zig:2666
//!   * std.posix.SIG.TERM                          — c.zig (macOS enum)
//!   * std.posix.pid_t                             — posix.zig (re-export of c.pid_t)
//!   * std.process.exit(u8)                        — process.zig:854

const std = @import("std");

// ---------------------------------------------------------------------------
// File-scope state for the async-signal-safe SIGINT handler.
// ---------------------------------------------------------------------------

var bun_pid: std.posix.pid_t = 0;

fn sigintHandler(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    if (bun_pid != 0) {
        std.posix.kill(bun_pid, .TERM) catch {};
    }
    std.process.exit(130);
}

// ---------------------------------------------------------------------------
// Poll helper
// ---------------------------------------------------------------------------

const POLL_INTERVAL_MS: i64 = 200;
const POLL_MAX_ATTEMPTS: u32 = 150; // 150 × 200 ms = 30 s

fn tcpProbe(io: std.Io) bool {
    // Try IPv6 loopback first (Vite defaults to ::1 on modern systems).
    const addr6 = std.Io.net.IpAddress{ .ip6 = std.Io.net.Ip6Address.loopback(5173) };
    if (std.Io.net.IpAddress.connect(&addr6, io, .{ .mode = .stream })) |*s| {
        s.close(io);
        return true;
    } else |_| {}
    // Fall back to IPv4 loopback.
    const addr4 = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(5173) };
    var s4 = std.Io.net.IpAddress.connect(&addr4, io, .{ .mode = .stream }) catch return false;
    s4.close(io);
    return true;
}

fn waitForVite(io: std.Io) bool {
    var attempt: u32 = 0;
    while (attempt < POLL_MAX_ATTEMPTS) : (attempt += 1) {
        if (tcpProbe(io)) return true;
        std.Io.sleep(
            io,
            std.Io.Duration.fromMilliseconds(POLL_INTERVAL_MS),
            .real,
        ) catch {};
    }
    return false;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip(); // argv[0]

    const frontend_dir = args.next() orelse {
        std.debug.print("usage: dev_runner <frontend_dir> <pid_file>\n", .{});
        std.process.exit(1);
    };
    const pid_file_path = args.next() orelse {
        std.debug.print("usage: dev_runner <frontend_dir> <pid_file>\n", .{});
        std.process.exit(1);
    };

    const sa = std.posix.Sigaction{
        .handler = .{ .handler = sigintHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &sa, null);

    var bun_child = std.process.spawn(io, .{
        .argv = &.{ "bun", "run", "dev" },
        .cwd = .{ .path = frontend_dir },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        std.debug.print("dev_runner: failed to spawn bun: {}\n", .{err});
        std.process.exit(1);
    };

    bun_pid = bun_child.id orelse {
        std.debug.print("dev_runner: bun child has no PID after spawn\n", .{});
        std.process.exit(1);
    };

    if (!waitForVite(io)) {
        bun_child.kill(io);
        bun_pid = 0;
        std.debug.print("dev_runner: Vite did not start on :5173 within 30s\n", .{});
        std.process.exit(1);
    }

    // Write bun PID to pid_file so the caller can kill it later.
    var pid_buf: [32]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&pid_buf, "{d}\n", .{bun_pid});
    try std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{
        .sub_path = pid_file_path,
        .data = pid_str,
    });

    // Vite is ready. Exit — bun continues running as an orphan in our process
    // group. The build system will now run the app as a direct child of zig build.
}
