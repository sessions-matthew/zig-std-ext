//! stdx: Zig Standard Library Extensions
//! Mirrors the structure and idioms of std, providing battle-tested utilities
//! for asynchronous I/O, networking, and systems programming.
//!
//! Designed and engineered in collaboration with Google DeepMind Gemini.

const std_builtin = @import("std");

/// Re-export the official standard library so consumers can optionally use stdx
/// as a superset root: `const std = @import("stdx");`
pub const std = std_builtin;

/// High-performance networking extensions (single-threaded event loops, async servers)
pub const net = @import("net/root.zig");

/// Thread-safe background workers and lock-free task pollers
pub const concurrency = @import("concurrency/root.zig");

/// 2D vectors, rects, transforms, camera projections, and hit testing
pub const math2d = @import("math2d/root.zig");

/// Pure-Zig Apple Objective-C runtime and Metal trampolines without @cImport
pub const objc = @import("objc/root.zig");

/// Cross-platform C-stdio fallback filesystem
pub const fs = @import("fs/root.zig");

/// Non-blocking subprocess execution and pipe poller
pub const process = @import("process/root.zig");

/// Type-hashed persistent state store and useState hooks
pub const state = @import("state/root.zig");

test {
    _ = net;
    _ = concurrency;
    _ = math2d;
    _ = objc;
    _ = fs;
    _ = process;
    _ = state;
}
