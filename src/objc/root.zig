//! stdx.objc: Pure-Zig Objective-C runtime & Metal trampolines without @cImport.
//!
//! Provides typed ARM64 `objc_msgSend` wrappers to prevent ABI register corruption on Apple Silicon.

const builtin = @import("builtin");
pub const is_macos = (builtin.os.tag == .macos);
pub const is_ios = (builtin.os.tag == .ios);
pub const is_apple = (is_macos or is_ios);

pub const id = ?*anyopaque;
pub const Class = ?*anyopaque;
pub const SEL = ?*anyopaque;
pub const Protocol = ?*anyopaque;
pub const CGFloat = f64;

pub const NSPoint = extern struct {
    x: CGFloat,
    y: CGFloat,
};

pub const NSSize = extern struct {
    width: CGFloat,
    height: CGFloat,
};

pub const NSRect = extern struct {
    origin: NSPoint,
    size: NSSize,
};

pub const c = if (is_apple) struct {
    pub extern "c" fn objc_getClass(name: [*:0]const u8) Class;
    pub extern "c" fn object_getClass(obj: id) Class;
    pub extern "c" fn objc_getMetaClass(name: [*:0]const u8) Class;
    pub extern "c" fn objc_getProtocol(name: [*:0]const u8) Protocol;
    pub extern "c" fn sel_registerName(str: [*:0]const u8) SEL;
    pub extern "c" fn objc_msgSend() void;
    pub extern "c" fn objc_autoreleasePoolPush() ?*anyopaque;
    pub extern "c" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;
    pub extern "c" fn MTLCreateSystemDefaultDevice() id;
} else struct {
    pub fn objc_getClass(_: [*:0]const u8) Class { return null; }
    pub fn object_getClass(_: id) Class { return null; }
    pub fn objc_getMetaClass(_: [*:0]const u8) Class { return null; }
    pub fn objc_getProtocol(_: [*:0]const u8) Protocol { return null; }
    pub fn sel_registerName(_: [*:0]const u8) SEL { return null; }
    pub fn objc_msgSend() void {}
    pub fn objc_autoreleasePoolPush() ?*anyopaque { return null; }
    pub fn objc_autoreleasePoolPop(_: ?*anyopaque) void {}
    pub fn MTLCreateSystemDefaultDevice() id { return null; }
};

/// Sends an Objective-C selector with 0 arguments.
pub fn msgSend0(recv: id, comptime Ret: type, sel_name: [*:0]const u8) Ret {
    if (!is_apple) return if (@typeInfo(Ret) == .optional) null else undefined;
    const fn_ptr: *const fn (id, SEL) callconv(.c) Ret = @ptrCast(&c.objc_msgSend);
    return fn_ptr(recv, c.sel_registerName(sel_name));
}

/// Sends an Objective-C selector with 1 argument.
pub fn msgSend1(recv: id, comptime Ret: type, sel_name: [*:0]const u8, a1: anytype) Ret {
    if (!is_apple) return if (@typeInfo(Ret) == .optional) null else undefined;
    const fn_ptr: *const fn (id, SEL, @TypeOf(a1)) callconv(.c) Ret = @ptrCast(&c.objc_msgSend);
    return fn_ptr(recv, c.sel_registerName(sel_name), a1);
}

/// Sends an Objective-C selector with 2 arguments.
pub fn msgSend2(recv: id, comptime Ret: type, sel_name: [*:0]const u8, a1: anytype, a2: anytype) Ret {
    if (!is_apple) return if (@typeInfo(Ret) == .optional) null else undefined;
    const fn_ptr: *const fn (id, SEL, @TypeOf(a1), @TypeOf(a2)) callconv(.c) Ret = @ptrCast(&c.objc_msgSend);
    return fn_ptr(recv, c.sel_registerName(sel_name), a1, a2);
}

test "objc: structure sizes and sel registration" {
    const std = @import("std");
    try std.testing.expectEqual(@sizeOf(CGFloat) * 2, @sizeOf(NSPoint));
    try std.testing.expectEqual(@sizeOf(CGFloat) * 4, @sizeOf(NSRect));

    if (is_apple) {
        const pool = c.objc_autoreleasePoolPush();
        defer c.objc_autoreleasePoolPop(pool);

        const sel = c.sel_registerName("init");
        try std.testing.expect(sel != null);
    }
}
