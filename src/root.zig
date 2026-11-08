//! stdx: Zig Standard Library Extensions
//! Mirrors the structure and idioms of std, providing battle-tested utilities
//! for asynchronous I/O, networking, profiling, text parsing, and systems programming.
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

/// Pure-Zig Apple platform utilities, Objective-C runtime, and Metal bridge
pub const apple = @import("apple/root.zig");

/// Compatibility alias for Objective-C runtime utilities
pub const objc = apple.objc;

/// Cross-platform C-stdio fallback filesystem
pub const fs = @import("fs/root.zig");

/// Non-blocking subprocess execution and pipe poller
pub const process = @import("process/root.zig");

/// Type-hashed persistent state store and useState hooks
pub const state = @import("state/root.zig");

/// Zero-allocation unified diff parser, hunk tracking, and split view builder
pub const diff = @import("diff/root.zig");

/// Performance telemetry, latency percentiles (P50/P90/P95/P99), and Chrome / Perfetto trace exporter
pub const trace = @import("trace/root.zig");

/// ANSI escape sequence parser, stripper, visible-width calculator, and SGR style formatter
pub const ansi = @import("ansi/root.zig");

test {
    _ = net;
    _ = concurrency;
    _ = math2d;
    _ = apple;
    _ = fs;
    _ = process;
    _ = state;
    _ = diff;
    _ = trace;
    _ = ansi;
}
