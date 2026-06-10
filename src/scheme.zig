//! Custom app:// URL scheme handler for embedded assets.
//!
//! Responsibility: a WKURLSchemeHandler that serves the @embedFile'd Vite
//! `dist/` bundle at app://local in release builds — path -> asset resolution,
//! MIME typing, and WKURLSchemeTask response/finish. Zero external assets at
//! runtime. Main thread only.
//!
//! M1.1 scaffold: no implementation yet (lands in M4.1).

const std = @import("std");
const objc = @import("objc");

comptime {
    _ = objc;
}

test {
    std.testing.refAllDecls(@This());
}
