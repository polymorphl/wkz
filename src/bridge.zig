//! Typed bidirectional JS <-> Zig bridge.
//!
//! Responsibility: the public bridge API. Registers a WKScriptMessageHandler
//! named "bridge", parses incoming messages (treated as HOSTILE input: shape and
//! size validated before std.json parse), dispatches to typed handlers, and
//! replies via evaluateJavaScript using an id-correlated __resolve(id, result)
//! convention. Every allocating function takes an Allocator.
//!
//! M1.1 scaffold: no implementation yet (lands in M2/M3).

const std = @import("std");
const objc = @import("objc");

comptime {
    _ = objc;
}

test {
    std.testing.refAllDecls(@This());
}
