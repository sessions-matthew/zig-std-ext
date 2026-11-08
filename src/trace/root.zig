//! stdx.trace: Performance profiling, latency percentiles, and Chrome / Perfetto trace exporter.

const stats = @import("stats.zig");
const chrome = @import("chrome.zig");

pub const LatencyStats = stats.LatencyStats;
pub const compute = stats.compute;
pub const computeFromSorted = stats.computeFromSorted;
pub const RollingBuffer = stats.RollingBuffer;

pub const Phase = chrome.Phase;
pub const TraceEvent = chrome.TraceEvent;
pub const serializeEvents = chrome.serializeEvents;
pub const TraceCollector = chrome.TraceCollector;

test {
    @import("std").testing.refAllDecls(@This());
    _ = stats;
    _ = chrome;
}
