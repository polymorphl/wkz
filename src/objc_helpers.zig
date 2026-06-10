//! Objective-C runtime glue shared across the library.
//!
//! Responsibility: thin, well-documented helpers over zig-objc for the patterns
//! wkz needs but the bindings don't package — runtime class creation
//! (allocateClassPair + method registration), selector/encoding helpers, and
//! NSObject lifetime conventions. No AppKit/WebKit specifics live here.
//!
//! Ownership rule (enforced from M2.1 on): every helper that creates or copies
//! an Objective-C object documents who releases it; there is no ARC.
//!
//! M1.1 scaffold: no implementation yet.

const std = @import("std");
const objc = @import("objc");

comptime {
    _ = objc; // bindings are wired; helpers land in M2.1
}

test {
    std.testing.refAllDecls(@This());
}
