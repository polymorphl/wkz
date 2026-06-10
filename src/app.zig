//! NSApplication bootstrap and lifecycle.
//!
//! Responsibility: create the shared NSApplication, set activation policy
//! (.regular), install the application menu (incl. Cmd+Q), and own the main run
//! loop. Everything here runs on the main thread.
//!
//! M1.1 scaffold: no implementation yet (lands in M1.2).

const std = @import("std");
const objc = @import("objc");

comptime {
    _ = objc;
}

test {
    std.testing.refAllDecls(@This());
}
