//! stdx.trace.stats: Pure-math latency distribution, percentile, and jitter computation.
//!
//! Provides zero-allocation percentiles (P50, P90, P95, P99), mean, min, max, and standard deviation
//! for benchmark timings, frame rendering telemetry, and distributed request profiling.

const std = @import("std");

pub const LatencyStats = struct {
    count: usize = 0,
    min: u64 = 0,
    max: u64 = 0,
    sum: u64 = 0,
    mean: f64 = 0.0,
    p50: u64 = 0,
    p90: u64 = 0,
    p95: u64 = 0,
    p99: u64 = 0,
    stddev: f64 = 0.0,
};

/// Computes percentile distribution and summary statistics over a mutable slice of samples.
/// Note: `samples` is sorted in-place.
pub fn computeFromSorted(sorted_samples: []const u64) LatencyStats {
    const count = sorted_samples.len;
    if (count == 0) return .{};

    var sum: u64 = 0;
    for (sorted_samples) |val| {
        sum += val;
    }

    const c_f64 = @as(f64, @floatFromInt(count));
    const mean = @as(f64, @floatFromInt(sum)) / c_f64;

    var var_sum: f64 = 0.0;
    for (sorted_samples) |val| {
        const diff = @as(f64, @floatFromInt(val)) - mean;
        var_sum += diff * diff;
    }
    const stddev = @sqrt(var_sum / c_f64);

    const p50_idx = (count * 50) / 100;
    const p90_idx = (count * 90) / 100;
    const p95_idx = (count * 95) / 100;
    const p99_idx = (count * 99) / 100;

    return .{
        .count = count,
        .min = sorted_samples[0],
        .max = sorted_samples[count - 1],
        .sum = sum,
        .mean = mean,
        .p50 = sorted_samples[p50_idx],
        .p90 = sorted_samples[@min(p90_idx, count - 1)],
        .p95 = sorted_samples[@min(p95_idx, count - 1)],
        .p99 = sorted_samples[@min(p99_idx, count - 1)],
        .stddev = stddev,
    };
}

/// Computes summary statistics over an arbitrary slice by copying into a temporary buffer
/// or sorting in place.
pub fn compute(samples: []u64) LatencyStats {
    if (samples.len == 0) return .{};
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return computeFromSorted(samples);
}

/// Fixed-capacity circular buffer for rolling latency tracking with zero heap allocations.
pub fn RollingBuffer(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buffer: [capacity]u64 = @splat(0),
        count: usize = 0,
        head: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn record(self: *Self, value: u64) void {
            self.buffer[self.head] = value;
            self.head = (self.head + 1) % capacity;
            if (self.count < capacity) {
                self.count += 1;
            }
        }

        pub fn reset(self: *Self) void {
            self.count = 0;
            self.head = 0;
        }

        pub fn computeStats(self: *const Self) LatencyStats {
            if (self.count == 0) return .{};
            var scratch: [capacity]u64 = undefined;
            @memcpy(scratch[0..self.count], self.buffer[0..self.count]);
            return compute(scratch[0..self.count]);
        }
    };
}

test "trace.stats: compute statistics from samples" {
    var data = [_]u64{ 100, 20, 50, 80, 10, 30, 90, 40, 70, 60 };
    const stats = compute(&data);

    try std.testing.expectEqual(@as(usize, 10), stats.count);
    try std.testing.expectEqual(@as(u64, 10), stats.min);
    try std.testing.expectEqual(@as(u64, 100), stats.max);
    try std.testing.expectEqual(@as(u64, 550), stats.sum);
    try std.testing.expectApproxEqAbs(@as(f64, 55.0), stats.mean, 0.001);
    try std.testing.expectEqual(@as(u64, 60), stats.p50);
    try std.testing.expectEqual(@as(u64, 100), stats.p90);
    try std.testing.expectEqual(@as(u64, 100), stats.p99);
}

test "trace.stats: RollingBuffer circular behavior" {
    var rb = RollingBuffer(5).init();
    rb.record(10);
    rb.record(20);
    rb.record(30);

    var s = rb.computeStats();
    try std.testing.expectEqual(@as(usize, 3), s.count);
    try std.testing.expectEqual(@as(u64, 10), s.min);
    try std.testing.expectEqual(@as(u64, 30), s.max);

    rb.record(40);
    rb.record(50);
    rb.record(60); // Overwrites 10
    s = rb.computeStats();
    try std.testing.expectEqual(@as(usize, 5), s.count);
    try std.testing.expectEqual(@as(u64, 20), s.min);
    try std.testing.expectEqual(@as(u64, 60), s.max);
}
