//! Objective-C runtime glue shared across the library.
//!
//! Responsibility: thin, well-documented helpers over zig-objc for the patterns
//! wkz needs but the bindings don't package cleanly — runtime class creation
//! (allocateClassPair + method registration + registerClassPair) and the
//! per-instance Zig-context attachment convention used by the bridge. No
//! AppKit/WebKit specifics live here.
//!
//! Lifetime rule: a registered Objective-C class lives for the entire process.
//! `objc_allocateClassPair`/`objc_registerClassPair` do NOT participate in
//! NSObject reference counting — there is nothing to release and registering a
//! class once for the process lifetime is correct, not a leak. The ARC rule
//! still applies to any *instances* of these classes the caller `alloc`s.
//!
//! Method-IMP convention (Objective-C runtime, verified against zig-objc
//! src/class.zig `addMethod`): an IMP is a Zig `fn` with the C calling
//! convention whose first two parameters are `objc.c.id` (self) and
//! `objc.c.SEL` (_cmd), followed by the method arguments. The Objective-C type
//! encoding string for the method is generated automatically by zig-objc's
//! `comptimeEncode` from the function type — wkz does NOT hand-write encoding
//! strings, which removes a whole class of "wrong encoding char" bugs. For
//! reference, the encodings comptimeEncode would emit are: `v`=void, `@`=id,
//! `:`=SEL, `i`=i32/int, `q`=i64/longlong, etc. (zig-objc src/encoding.zig).

const std = @import("std");
const objc = @import("objc");

/// Errors surfaced while creating a runtime class.
pub const Error = error{
    /// `objc_allocateClassPair` returned nil. This happens when the requested
    /// class name is already registered in the runtime, or (rarely) when the
    /// runtime cannot allocate the pair. Class names must be unique per process.
    ClassRegistrationFailed,
};

/// Create (or look up) an Objective-C class named `name` subclassing
/// `superclass`, register the methods described by `methods`, and return the
/// registered `objc.Class`.
///
/// Re-run safety: if a class named `name` is already registered in the runtime
/// (e.g. this is called twice in one process, as a test re-run would do), the
/// existing class is returned as-is and no new pair is allocated. This makes
/// `defineClass` idempotent for a fixed `name` — the caller must therefore use
/// a process-unique `name` per distinct class shape, because the *first*
/// registration wins and later differing `methods` are ignored. This matches
/// the runtime semantics: `objc_allocateClassPair` fails (nil) on a duplicate
/// name, so guarding with a lookup is the only safe pattern.
///
/// Lifetime: the returned class is owned by the runtime and lives for the
/// process. There is nothing to release. No ARC interaction.
///
/// Must be called on the main thread (the runtime calls are thread-safe, but we
/// keep all runtime mutation on the main thread for consistency with the rest
/// of wkz).
///
/// `methods` is a comptime tuple where each element is a struct literal of the
/// form `.{ .name = <selector>, .imp = <fn> }` (see the `method` helper). Each
/// is registered via `class_addMethod`. The `imp` must satisfy the IMP
/// convention documented at the top of this file (C calling convention,
/// `objc.c.id` + `objc.c.SEL` first). Its type encoding is derived from the
/// function type automatically — no hand-written encoding strings. `imp` is kept
/// with its concrete function type (not erased) so zig-objc can introspect it.
pub fn defineClass(
    comptime name: [:0]const u8,
    superclass: objc.Class,
    comptime methods: anytype,
) Error!objc.Class {
    // Idempotent: if already registered, return the existing class. Guards
    // against double-registration when the same name is defined twice in one
    // process (test re-runs, repeated bridge setup).
    if (objc.getClass(name)) |existing| return existing;

    // objc_allocateClassPair(superclass, name, extraBytes=0) — zig-objc hardcodes
    // extraBytes to 0 (src/class.zig:107-113). Returns nil if `name` already
    // exists; we handled that above, so a nil here is a genuine failure.
    const cls = objc.allocateClassPair(superclass, name) orelse
        return Error.ClassRegistrationFailed;

    // Register each method before the class pair is registered. class_addMethod
    // must run between allocateClassPair and registerClassPair.
    inline for (methods) |m| {
        // Class.addMethod asserts the IMP's calling convention and that its
        // first two params are objc.c.id / objc.c.SEL, then derives the type
        // encoding from the fn type. Returns false only if a method with that
        // selector already exists on the class — impossible on a fresh pair, so
        // a false result is a programming error in the caller's method set.
        const ok = cls.addMethod(m.name, m.imp);
        std.debug.assert(ok);
    }

    // Make the class visible to the runtime. After this it is a usable class.
    objc.registerClassPair(cls);
    return cls;
}

/// Add a single `id`-typed instance variable named `name` to `cls`.
///
/// This MUST be called on a class returned by `objc.allocateClassPair` that has
/// NOT yet been registered — `class_addIvar` is only legal between
/// allocateClassPair and registerClassPair. M2.1 does not register ivars itself
/// (see the context-attachment note below); this helper exists so M2.2 can,
/// when it wires the bridge pointer onto the handler instance.
///
/// Returns `true` on success. The ivar holds an `id` (pointer-width); the bridge
/// will store a boxed pointer-back-to-Zig in it.
///
/// Per-instance Zig context (decided here for M2.2): the WKScriptMessageHandler
/// subclass will carry one `id`-typed ivar (added via this helper, or via a
/// dedicated ivar at class-definition time) holding an opaque pointer to the
/// Zig-side bridge state. The IMP recovers it with
/// `object_getInstanceVariable` (wrapped by `objc.Object.getInstanceVariable`).
/// We chose an ivar over `objc_setAssociatedObject` because: (a) the handler is
/// a wkz-private subclass we fully control, so reserving a field is clean and
/// has no collision risk; (b) ivar access is a plain pointer read with no
/// association-table lookup or extra retain semantics to reason about under the
/// no-ARC rule. M2.1 deliberately implements only the primitive; the bridge
/// wires the actual pointer in M2.2.
pub fn addIvar(cls: objc.Class, name: [:0]const u8) bool {
    return cls.addIvar(name);
}

// --- A single method to register on a runtime class. ---

/// Build a method-spec entry for `defineClass`'s `methods` tuple from a selector
/// name and an IMP function value.
///
/// `name` is the selector string (e.g. `"userContentController:didReceiveScriptMessage:"`).
/// `imp` is the IMP function — C calling convention, first two params
/// `objc.c.id` (self) and `objc.c.SEL` (_cmd). The returned struct keeps `imp`
/// with its *concrete function type* (the field type is `@TypeOf(imp)`), because
/// `Class.addMethod` introspects the function type at comptime to derive the
/// Objective-C type encoding. Do not hand-write the encoding.
pub fn method(comptime name: [:0]const u8, comptime imp: anytype) struct {
    name: [:0]const u8,
    imp: @TypeOf(imp),
} {
    return .{ .name = name, .imp = imp };
}

// =====================================================================
// Tests — runtime class creation IS headless-safe (no window server), so
// these are LIVE: create a class pair, add methods, register, instantiate,
// send the message, and assert the IMP ran and returned the right value.
// =====================================================================

const c = objc.c;

// --- IMP functions used by the live tests. ---
//
// Each follows the IMP convention: C calling convention, first two params
// id self / SEL _cmd. zig-objc derives the encoding from the signature.

/// Returns a fixed sentinel — proves the IMP ran and its return value flows
/// back through objc_msgSend. Encoding: `q@:` (i64 return, id self, SEL _cmd).
fn impAnswer(self: c.id, sel: c.SEL) callconv(.c) i64 {
    _ = self;
    _ = sel;
    return 42;
}

/// Adds two i32 args — proves arguments are marshalled correctly.
/// Encoding: `i@:ii` (i32 return, id self, SEL _cmd, i32, i32).
fn impAdd(self: c.id, sel: c.SEL, a: i32, b: i32) callconv(.c) i32 {
    _ = self;
    _ = sel;
    return a + b;
}

/// Module-level flag a void IMP sets, proving a `v`-return IMP executed.
var flag_ran: bool = false;

/// Sets `flag_ran` — proves a void-returning IMP body executed.
/// Encoding: `v@:` (void return, id self, SEL _cmd).
fn impSetFlag(self: c.id, sel: c.SEL) callconv(.c) void {
    _ = self;
    _ = sel;
    flag_ran = true;
}

/// Mixed-width / mixed-type IMP — exercises encoding + C-ABI marshalling across
/// several distinct argument widths in one call (not just the uniform i32,i32
/// of impAdd). Encoding comptimeEncode emits: `q@:qiB` (i64 return, id self,
/// SEL _cmd, i64, i32, bool). Returns a value that depends on every argument so
/// a misencoded/misaligned slot would corrupt the result.
fn impMixed(self: c.id, sel: c.SEL, a: i64, b: i32, flip: bool) callconv(.c) i64 {
    _ = self;
    _ = sel;
    return if (flip) a + b else a - b;
}

test "defineClass creates a class, registers methods, and the IMPs run" {
    // Unique per-process class name so a re-run inside the same process hits
    // the idempotent lookup path rather than re-allocating.
    const NSObject = objc.getClass("NSObject").?;

    const Cls = try defineClass("WkzTestHelperClass", NSObject, .{
        method("answer", impAnswer),
        method("addInts:to:", impAdd),
        method("setFlag", impSetFlag),
    });

    // Class lookup: the class is now visible in the runtime by name.
    try std.testing.expect(objc.getClass("WkzTestHelperClass") != null);
    try std.testing.expectEqual(objc.getClass("WkzTestHelperClass").?.value, Cls.value);

    // Method response: instances respond to every selector we registered.
    try std.testing.expect(Cls.msgSend(bool, "instancesRespondToSelector:", .{objc.sel("answer").value}));
    try std.testing.expect(Cls.msgSend(bool, "instancesRespondToSelector:", .{objc.sel("addInts:to:").value}));
    try std.testing.expect(Cls.msgSend(bool, "instancesRespondToSelector:", .{objc.sel("setFlag").value}));

    // Instantiate (+1) and release it on every path (no ARC).
    const obj = Cls.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer obj.msgSend(void, "release", .{});

    // Return value: the no-arg IMP returns its sentinel.
    try std.testing.expectEqual(@as(i64, 42), obj.msgSend(i64, "answer", .{}));

    // Arguments: the two-arg IMP marshals and sums correctly.
    try std.testing.expectEqual(
        @as(i32, 5),
        obj.msgSend(i32, "addInts:to:", .{ @as(i32, 2), @as(i32, 3) }),
    );

    // Side effect: the void IMP's body ran (flag flipped from false to true).
    flag_ran = false;
    obj.msgSend(void, "setFlag", .{});
    try std.testing.expect(flag_ran);
}

test "defineClass marshals mixed-width / mixed-type arguments correctly" {
    // Beyond the uniform (i32,i32) of the existing add test: register an IMP
    // taking (i64, i32, bool) and assert both the boolean branch *and* the
    // arithmetic across differing argument widths come back correct. A wrong
    // type encoding or a misaligned ABI slot would scramble one of these.
    const NSObject = objc.getClass("NSObject").?;
    const Cls = try defineClass("WkzTestMixedArgsClass", NSObject, .{
        method("mix:and:flip:", impMixed),
    });

    const obj = Cls.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer obj.msgSend(void, "release", .{});

    // flip = true  -> a + b
    try std.testing.expectEqual(
        @as(i64, 1_000_003),
        obj.msgSend(i64, "mix:and:flip:", .{ @as(i64, 1_000_000), @as(i32, 3), true }),
    );
    // flip = false -> a - b. Use a 64-bit value that does not fit in i32 to
    // prove the i64 slot is not being truncated to 32 bits.
    try std.testing.expectEqual(
        @as(i64, 5_000_000_000 - 7),
        obj.msgSend(i64, "mix:and:flip:", .{ @as(i64, 5_000_000_000), @as(i32, 7), false }),
    );
}

test "defineClass'd instances do NOT respond to an unregistered selector" {
    // Negative counterpart to the positive instancesRespondToSelector: checks in
    // the main test: a selector we never registered must report false. Guards
    // against instancesRespondToSelector: trivially returning true (which would
    // make the positive assertions meaningless) and documents that defineClass
    // registers exactly the methods handed to it — no phantom selectors.
    const NSObject = objc.getClass("NSObject").?;
    const Cls = try defineClass("WkzTestNegativeRespClass", NSObject, .{
        method("answer", impAnswer),
    });
    // Registered selector: responds.
    try std.testing.expect(Cls.msgSend(bool, "instancesRespondToSelector:", .{objc.sel("answer").value}));
    // Never-registered selector: must NOT respond. (NSObject itself does not
    // implement this contrived selector either, so a true here would be a bug.)
    try std.testing.expect(!Cls.msgSend(bool, "instancesRespondToSelector:", .{objc.sel("wkzNeverRegisteredSelector").value}));
}

test "addIvar returns false after the class pair is registered" {
    // class_addIvar is only legal between allocateClassPair and
    // registerClassPair. Adding an ivar to an already-registered class must
    // fail (return false), not silently corrupt the layout. This pins the false
    // branch of addIvar, which the M2.2 context path relies on to be honest.
    const NSObject = objc.getClass("NSObject").?;

    // Build and fully register a pair with no ivar, then try to add one late.
    if (objc.getClass("WkzTestLateIvarClass") == null) {
        const cls = objc.allocateClassPair(NSObject, "WkzTestLateIvarClass").?;
        objc.registerClassPair(cls);
    }
    const registered = objc.getClass("WkzTestLateIvarClass").?;

    // Adding an ivar after registration is illegal -> false.
    try std.testing.expect(!addIvar(registered, "wkz_late"));
}

test "addIvar returns false for a duplicate ivar on the same unregistered pair" {
    // Two ivars of the same name on one (still-unregistered) class pair: the
    // first add succeeds, the second must fail. Confirms addIvar surfaces the
    // runtime's duplicate rejection rather than reporting success twice.
    const NSObject = objc.getClass("NSObject").?;

    // A throwaway pair we never register; dispose it so the name is reusable and
    // no half-built class leaks into the runtime's class list.
    const cls = objc.allocateClassPair(NSObject, "WkzTestDupIvarClass").?;
    defer objc.disposeClassPair(cls);

    try std.testing.expect(addIvar(cls, "wkz_dup"));
    try std.testing.expect(!addIvar(cls, "wkz_dup"));
}

test "defineClass is idempotent for a repeated name (re-run safe)" {
    // Defining the same name twice must not fail or re-allocate: the second
    // call returns the already-registered class. This is what makes a single
    // `zig build test` process safe even if the test graph touches the name
    // more than once.
    const NSObject = objc.getClass("NSObject").?;
    const first = try defineClass("WkzTestIdempotentClass", NSObject, .{
        method("answer", impAnswer),
    });
    const second = try defineClass("WkzTestIdempotentClass", NSObject, .{
        method("answer", impAnswer),
    });
    try std.testing.expectEqual(first.value, second.value);
}

test "addIvar adds an id ivar that survives a round-trip (M2.2 context path)" {
    // Proves the per-instance-context mechanism M2.2 will use: an `id` ivar
    // added before registration, written and read back on an instance.
    const NSObject = objc.getClass("NSObject").?;

    // Build the pair manually here (not via defineClass) because the ivar must
    // be added before registerClassPair, and we want to exercise addIvar.
    if (objc.getClass("WkzTestIvarClass") == null) {
        const cls = objc.allocateClassPair(NSObject, "WkzTestIvarClass").?;
        try std.testing.expect(addIvar(cls, "wkz_ctx"));
        objc.registerClassPair(cls);
    }
    const Cls = objc.getClass("WkzTestIvarClass").?;

    const obj = Cls.msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "init", .{});
    defer obj.msgSend(void, "release", .{});

    // Store an NSString in the ivar and read it back (round-trip proves the
    // ivar slot exists and is wired). The stored object is owned by the ivar
    // assignment path here; NSString from stringWithUTF8String: is autoreleased
    // (we drain no pool), so we do not over-release it.
    const NSString = objc.getClass("NSString").?;
    const str = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"ctx"});
    obj.setInstanceVariable("wkz_ctx", str);

    const got = obj.getInstanceVariable("wkz_ctx");
    try std.testing.expect(got.value != null);
    const utf8 = got.msgSend([*:0]const u8, "UTF8String", .{});
    try std.testing.expectEqualStrings("ctx", std.mem.span(utf8));
}

// --- API-surface / type contract (compile-time) ---

test "Error set is exactly {ClassRegistrationFailed}" {
    const fields = @typeInfo(Error).error_set.?;
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("ClassRegistrationFailed", fields[0].name);
}

test "defineClass exposes the documented signature" {
    // Returns Error!objc.Class.
    const Ret = @typeInfo(@TypeOf(defineClass)).@"fn".return_type.?;
    try std.testing.expectEqual(Error!objc.Class, Ret);

    // addIvar returns bool.
    try std.testing.expectEqual(bool, @typeInfo(@TypeOf(addIvar)).@"fn".return_type.?);

    // method() returns a spec struct carrying a selector name and the IMP with
    // its concrete function type preserved (needed for encoding derivation).
    const spec = method("answer", impAnswer);
    try std.testing.expect(@hasField(@TypeOf(spec), "name"));
    try std.testing.expect(@hasField(@TypeOf(spec), "imp"));
    try std.testing.expectEqual([:0]const u8, @FieldType(@TypeOf(spec), "name"));
    try std.testing.expectEqual(@TypeOf(impAnswer), @FieldType(@TypeOf(spec), "imp"));
}

test {
    std.testing.refAllDecls(@This());
}
