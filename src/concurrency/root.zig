//! stdx.concurrency: Lock-free background workers and thread coordination.

pub const async_task = @import("async_task.zig");
pub const AsyncTask = async_task.AsyncTask;

test {
    _ = async_task;
}
