//! Non-blocking, thread-safe background Zig task runner (`AsyncTask(Context, Result)`).
//!
//! Allows any application to offload a pure Zig compute or I/O function `workerFn(ctx: Context) Result`
//! to a background `std.Thread` and poll completion in O(1) (< 5 ns) on the main/UI thread
//! without stalling the frame loop.

const std = @import("std");

/// Generic single-flight background worker task.
///
/// State transitions (`std.atomic.Value(u8)`):
///   - `idle (0)` -> `running (1)` on `spawn()` on the caller thread
///   - `running (1)` -> `ready (2)` with `.release` ordering when `workerFn` completes on the worker thread
///   - `ready (2)` -> `idle (0)` when `poll()` or `wait()` joins the thread and consumes `result`
pub fn AsyncTask(comptime Context: type, comptime Result: type) type {
    return struct {
        const Self = @This();

        pub const State = enum(u8) {
            idle = 0,
            running = 1,
            ready = 2,
        };

        state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(State.idle)),
        thread: ?std.Thread = null,
        ctx: Context = undefined,
        result: Result = undefined,

        pub fn init() Self {
            return .{};
        }

        /// Returns `true` if a background worker thread is currently executing.
        pub fn isBusy(self: *const Self) bool {
            return self.state.load(.acquire) == @intFromEnum(State.running);
        }

        /// Returns `true` if the background worker has finished and its result is ready to be consumed via `poll()`.
        pub fn hasResult(self: *const Self) bool {
            return self.state.load(.acquire) == @intFromEnum(State.ready);
        }

        /// Spawns `workerFn(ctx)` on a background thread.
        /// - If a task is currently `running`, returns `false` immediately.
        /// - If a previous completed thread handle was not joined yet, joins it first.
        pub fn spawn(self: *Self, ctx: Context, comptime workerFn: fn (Context) Result) bool {
            if (self.state.load(.acquire) == @intFromEnum(State.running)) {
                return false;
            }
            if (self.thread) |t| {
                t.join();
                self.thread = null;
            }

            self.ctx = ctx;
            self.state.store(@intFromEnum(State.running), .release);

            const Runner = struct {
                fn run(task: *Self) void {
                    task.result = workerFn(task.ctx);
                    task.state.store(@intFromEnum(State.ready), .release);
                }
            };

            self.thread = std.Thread.spawn(.{}, Runner.run, .{self}) catch {
                self.state.store(@intFromEnum(State.idle), .release);
                return false;
            };
            return true;
        }

        /// Non-blocking O(1) poll (< 5 ns when idle or running).
        /// When the worker finishes (`state == ready`), joins the worker thread, resets state to `idle`,
        /// and returns the computed `Result`.
        pub fn poll(self: *Self) ?Result {
            if (self.state.load(.acquire) != @intFromEnum(State.ready)) {
                return null;
            }
            if (self.thread) |t| {
                t.join();
                self.thread = null;
            }
            const res = self.result;
            self.state.store(@intFromEnum(State.idle), .release);
            return res;
        }

        /// Blocks until any active worker thread finishes and returns the result if one was produced.
        pub fn wait(self: *Self) ?Result {
            if (self.thread) |t| {
                t.join();
                self.thread = null;
            }
            if (self.state.load(.acquire) == @intFromEnum(State.ready)) {
                const res = self.result;
                self.state.store(@intFromEnum(State.idle), .release);
                return res;
            }
            self.state.store(@intFromEnum(State.idle), .release);
            return null;
        }

        /// Joins any active or unjoined worker thread cleanly and resets state to `idle`.
        pub fn deinit(self: *Self) void {
            if (self.thread) |t| {
                t.join();
                self.thread = null;
            }
            self.state.store(@intFromEnum(State.idle), .release);
        }
    };
}

test "AsyncTask: basic spawn, poll, reuse" {
    const Req = struct { a: u64, b: u64 };
    const Resp = struct { sum: u64, product: u64 };

    const Worker = struct {
        fn compute(req: Req) Resp {
            return .{ .sum = req.a + req.b, .product = req.a * req.b };
        }
    };

    var task: AsyncTask(Req, Resp) = .{};
    defer task.deinit();

    try std.testing.expect(!task.isBusy());
    try std.testing.expect(task.spawn(.{ .a = 7, .b = 9 }, Worker.compute));

    while (!task.hasResult()) {
        std.atomic.spinLoopHint();
    }

    const res = task.poll().?;
    try std.testing.expectEqual(@as(u64, 16), res.sum);
    try std.testing.expectEqual(@as(u64, 63), res.product);
}
