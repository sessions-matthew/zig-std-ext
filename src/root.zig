//! stdx: Zig Standard Library Extensions
//! Mirrors the structure and idioms of std, providing battle-tested utilities
//! for asynchronous I/O, networking, and systems programming.

const std_builtin = @import("std");

/// Re-export the standard library so consumers can optionally use stdx
/// as a superset root: `const std = @import("stdx");`
pub const std = std_builtin;

/// High-performance networking extensions (single-threaded event loops, async servers)
pub const net = @import("net/root.zig");

test {
    _ = net;
}
