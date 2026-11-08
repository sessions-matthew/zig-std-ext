//! Non-blocking Subprocess & Pipe Poller.
//!
//! Spawns child processes with non-blocking pipes and drains stdout incrementally into a
//! fixed buffer without stalling the interactive frame loop.

const std = @import("std");
const builtin = @import("builtin");
const is_windows = (builtin.os.tag == .windows);

const posix_c = if (!is_windows) struct {
    extern "c" fn pipe(fds: *[2]c_int) c_int;
    extern "c" fn fork() c_int;
    extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;
    extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
} else struct {};

const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = if (builtin.os.tag == .linux) 0x0800 else 0x0004;
const WNOHANG: c_int = 1;

const POLLIN: i16 = 0x0001;
const POLLHUP: i16 = 0x0010;
const POLLERR: i16 = 0x0008;

const PollFd = extern struct {
    fd: c_int,
    events: i16,
    revents: i16,
};

const c_poll = if (!is_windows) struct {
    extern "c" fn poll(fds: [*]PollFd, nfds: c_uint, timeout: c_int) c_int;
} else struct {};

pub fn SubprocessPoller(comptime capacity: usize) type {
    return struct {
        fd: c_int = -1,
        child_pid: c_int = -1,
        zombie_pids: [8]c_int = @splat(-1),
        buf: [capacity]u8 = undefined,
        len: usize = 0,
        pending_cmd: [512:0]u8 = @splat(0),
        pending_len: usize = 0,

        const Self = @This();

        fn reapZombies(self: *Self) void {
            if (comptime is_windows) return;
            for (&self.zombie_pids) |*zpid| {
                if (zpid.* > 0) {
                    const rc = std.c.waitpid(zpid.*, null, WNOHANG);
                    if (rc != 0) {
                        zpid.* = -1;
                    }
                }
            }
        }

        fn retireChildPid(self: *Self, pid: c_int) void {
            if (comptime is_windows) return;
            if (pid <= 0) return;
            if (std.c.waitpid(pid, null, WNOHANG) != 0) return;
            for (&self.zombie_pids) |*zpid| {
                if (zpid.* <= 0) {
                    zpid.* = pid;
                    return;
                }
            }
        }

        pub fn isBusy(self: *const Self) bool {
            return self.fd >= 0 or self.pending_len > 0;
        }

        pub fn request(self: *Self, cmd_str: []const u8) void {
            if (cmd_str.len == 0) return;
            const copy_len = @min(cmd_str.len, self.pending_cmd.len - 1);
            @memcpy(self.pending_cmd[0..copy_len], cmd_str[0..copy_len]);
            self.pending_cmd[copy_len] = 0;
            self.pending_len = copy_len;
        }

        fn launchPending(self: *Self) void {
            if (comptime is_windows) return;
            if (self.pending_len == 0 or self.fd >= 0) return;

            var fds: [2]c_int = undefined;
            if (posix_c.pipe(&fds) != 0) return;

            const flags = std.c.fcntl(fds[0], F_GETFL, @as(c_int, 0));
            _ = std.c.fcntl(fds[0], F_SETFL, flags | O_NONBLOCK);

            const pid = posix_c.fork();
            if (pid == 0) {
                // Child
                _ = std.c.close(fds[0]);
                _ = posix_c.dup2(fds[1], 1); // stdout
                _ = posix_c.dup2(fds[1], 2); // stderr
                _ = std.c.close(fds[1]);

                const sh: [*:0]const u8 = "/bin/sh";
                const flag_c: [*:0]const u8 = "-c";
                const argv = [_:null]?[*:0]const u8{ sh, flag_c, &self.pending_cmd, null };
                _ = posix_c.execv(sh, &argv);
                std.c.exit(127);
            } else if (pid > 0) {
                // Parent
                _ = std.c.close(fds[1]);
                self.fd = fds[0];
                self.child_pid = pid;
                self.len = 0;
                self.pending_len = 0;
            } else {
                _ = std.c.close(fds[0]);
                _ = std.c.close(fds[1]);
            }
        }

        pub fn poll(self: *Self) ?[]const u8 {
            self.reapZombies();

            if (self.fd < 0 and self.pending_len > 0) {
                self.launchPending();
            }

            if (self.fd < 0) return null;

            if (comptime !is_windows) {
                var pfd = PollFd{
                    .fd = self.fd,
                    .events = POLLIN | POLLHUP | POLLERR,
                    .revents = 0,
                };
                const rc = c_poll.poll(@ptrCast(&pfd), 1, 0);
                if (rc <= 0) return null;

                while (self.len < capacity) {
                    const n = std.c.read(self.fd, self.buf[self.len..].ptr, capacity - self.len);
                    if (n > 0) {
                        self.len += @intCast(n);
                    } else if (n == 0) {
                        // EOF
                        _ = std.c.close(self.fd);
                        self.fd = -1;
                        self.retireChildPid(self.child_pid);
                        self.child_pid = -1;
                        return self.buf[0..self.len];
                    } else {
                        break;
                    }
                }

                if (pfd.revents & (POLLHUP | POLLERR) != 0) {
                    _ = std.c.close(self.fd);
                    self.fd = -1;
                    self.retireChildPid(self.child_pid);
                    self.child_pid = -1;
                    return self.buf[0..self.len];
                }
            }

            return null;
        }

        pub fn deinit(self: *Self) void {
            if (self.fd >= 0) {
                _ = std.c.close(self.fd);
                self.fd = -1;
            }
            if (self.child_pid > 0) {
                _ = std.c.kill(self.child_pid, .KILL);
                _ = std.c.waitpid(self.child_pid, null, WNOHANG);
                self.child_pid = -1;
            }
            self.reapZombies();
        }
    };
}

test "SubprocessPoller: non-blocking echo" {
    if (builtin.os.tag == .windows) return;

    var poller = SubprocessPoller(256){};
    defer poller.deinit();

    poller.request("printf 'stdx_poller_ok'");
    try std.testing.expect(poller.isBusy());

    var result: ?[]const u8 = null;
    var attempts: usize = 0;
    while (attempts < 1000) : (attempts += 1) {
        if (poller.poll()) |payload| {
            result = payload;
            break;
        }
        const ts = std.c.timespec{ .sec = 0, .nsec = 1_000_000 };
        _ = std.c.nanosleep(&ts, null);
    }

    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("stdx_poller_ok", result.?);
}
