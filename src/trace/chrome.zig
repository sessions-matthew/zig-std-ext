//! stdx.trace.chrome: Chrome / Perfetto Catapult JSON Trace Event exporter.
//!
//! Generates standard JSON trace files compatible with `chrome://tracing`, `ui.perfetto.dev`,
//! and Speedscope for interactive timeline analysis, flame charts, and frame profiling.

const std = @import("std");

pub const Phase = enum(u8) {
    complete = 'X',
    instant = 'i',
    begin = 'B',
    end = 'E',
    counter = 'C',
    async_begin = 'b',
    async_end = 'e',
};

pub const TraceEvent = struct {
    name: []const u8,
    cat: []const u8 = "default",
    ph: u8 = 'X',
    ts_us: u64,
    dur_us: u64 = 0,
    pid: u32 = 1,
    tid: u32 = 1,
};

/// Serializes a slice of `TraceEvent` objects into standard Perfetto/Chrome JSON array format.
pub fn serializeEvents(events: []const TraceEvent, writer: anytype) !void {
    try writer.writeAll("[\n");
    for (events, 0..) |ev, idx| {
        try writer.print(
            "  {{\"name\":\"{s}\",\"cat\":\"{s}\",\"ph\":\"{c}\",\"ts\":{d},\"dur\":{d},\"pid\":{d},\"tid\":{d}}}",
            .{ ev.name, ev.cat, ev.ph, ev.ts_us, ev.dur_us, ev.pid, ev.tid },
        );
        if (idx + 1 < events.len) {
            try writer.writeAll(",\n");
        } else {
            try writer.writeAll("\n");
        }
    }
    try writer.writeAll("]\n");
}

/// Dynamic trace collector that buffers timeline events and exports to JSON.
pub const TraceCollector = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(TraceEvent) = .empty,
    base_ns: u64 = 0,
    enabled: bool = true,

    pub fn init(allocator: std.mem.Allocator) TraceCollector {
        return .{
            .allocator = allocator,
            .events = .empty,
            .base_ns = 0,
            .enabled = true,
        };
    }

    pub fn deinit(self: *TraceCollector) void {
        self.events.deinit(self.allocator);
    }

    pub fn clear(self: *TraceCollector) void {
        self.events.clearRetainingCapacity();
    }

    pub fn setBaseTimestamp(self: *TraceCollector, base_ns: u64) void {
        self.base_ns = base_ns;
    }

    /// Records a complete duration event (ph = 'X') with start and end nanoseconds.
    pub fn record(self: *TraceCollector, name: []const u8, cat: []const u8, start_ns: u64, end_ns: u64) !void {
        if (!self.enabled) return;
        const ts_us = if (start_ns >= self.base_ns) (start_ns - self.base_ns) / 1000 else 0;
        const dur_us = if (end_ns >= start_ns) (end_ns - start_ns) / 1000 else 0;
        try self.events.append(self.allocator, .{
            .name = name,
            .cat = cat,
            .ph = 'X',
            .ts_us = ts_us,
            .dur_us = dur_us,
            .pid = 1,
            .tid = 1,
        });
    }

    /// Records an instant event (ph = 'i') at timestamp.
    pub fn recordInstant(self: *TraceCollector, name: []const u8, cat: []const u8, timestamp_ns: u64) !void {
        if (!self.enabled) return;
        const ts_us = if (timestamp_ns >= self.base_ns) (timestamp_ns - self.base_ns) / 1000 else 0;
        try self.events.append(self.allocator, .{
            .name = name,
            .cat = cat,
            .ph = 'i',
            .ts_us = ts_us,
            .dur_us = 0,
            .pid = 1,
            .tid = 1,
        });
    }

    /// Serializes buffered events to an allocated string.
    pub fn exportJsonAlloc(self: *const TraceCollector, allocator: std.mem.Allocator) ![]u8 {
        var aw = std.Io.Writer.Allocating.init(allocator);
        errdefer aw.deinit();
        try serializeEvents(self.events.items, &aw.writer);
        var list = aw.toArrayList();
        return list.toOwnedSlice(allocator);
    }
};

test "trace.chrome: serializeEvents JSON output" {
    const events = [_]TraceEvent{
        .{ .name = "frame", .cat = "ui", .ph = 'X', .ts_us = 100, .dur_us = 50, .pid = 1, .tid = 1 },
        .{ .name = "vblank", .cat = "gpu", .ph = 'i', .ts_us = 155, .dur_us = 0, .pid = 1, .tid = 1 },
    };

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try serializeEvents(&events, &aw.writer);

    const json = aw.writer.buffer[0..aw.writer.end];
    try std.testing.expect(std.mem.startsWith(u8, json, "[\n"));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"frame\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"vblank\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, json, "]\n"));
}

test "trace.chrome: TraceCollector record and export" {
    var tc = TraceCollector.init(std.testing.allocator);
    defer tc.deinit();

    tc.setBaseTimestamp(1_000_000);
    try tc.record("render", "gfx", 1_000_000, 1_050_000);
    try tc.recordInstant("swap", "gfx", 1_055_000);

    const json = try tc.exportJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"ts\":0,\"dur\":50") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ph\":\"i\",\"ts\":55") != null);
}
