//! stdx.process: Subprocess management, non-blocking pipes, and poller abstractions.

pub const pipe_poller = @import("pipe_poller.zig");
pub const SubprocessPoller = pipe_poller.SubprocessPoller;

test {
    _ = pipe_poller;
}
