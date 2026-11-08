//! Single-threaded multiplexed TCP server using non-blocking I/O (poll/kqueue).
//! Runs on the caller thread without spawning background worker threads.

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const testing = std.testing;

pub const AsyncServer = struct {
    io: Io,
    server: Io.net.Server,
    clients: [MAX_CLIENTS]?Io.net.Stream = @splat(null),
    running: bool = true,

    pub const MAX_CLIENTS = 128;
    pub const DEFAULT_BUF_SIZE = 2048;

    pub const Options = struct {
        port: u16 = 8080,
        address: []const u8 = "127.0.0.1",
        kernel_backlog: u31 = 128,
        reuse_address: bool = true,
        poll_timeout_ms: i32 = 1000,
    };

    pub const Response = struct {
        stream: Io.net.Stream,
        io: Io,

        /// Send raw bytes back to the client
        pub fn send(self: Response, bytes: []const u8) !void {
            var tx_buf: [DEFAULT_BUF_SIZE]u8 = undefined;
            var writer = Io.net.Stream.Writer.init(self.stream, self.io, &tx_buf);
            _ = try writer.interface.writeAll(bytes);
            _ = try writer.interface.flush();
        }

        /// Formatted print back to the client
        pub fn print(self: Response, comptime fmt: []const u8, args: anytype) !void {
            var tx_buf: [DEFAULT_BUF_SIZE]u8 = undefined;
            var writer = Io.net.Stream.Writer.init(self.stream, self.io, &tx_buf);
            try writer.interface.print(fmt, args);
            try writer.interface.flush();
        }
    };

    pub fn init(io: Io, options: Options) !AsyncServer {
        const addr = try Io.net.IpAddress.parse(options.address, options.port);
        const server = try addr.listen(io, .{
            .reuse_address = options.reuse_address,
            .kernel_backlog = options.kernel_backlog,
        });
        return AsyncServer{
            .io = io,
            .server = server,
        };
    }

    pub fn deinit(self: *AsyncServer) void {
        for (&self.clients) |*slot| {
            if (slot.*) |s| s.close(self.io);
        }
        self.server.deinit(self.io);
    }

    /// Stop the server event loop gracefully
    pub fn stop(self: *AsyncServer) void {
        self.running = false;
    }

    /// Run the single-threaded event loop, dispatching messages to `handler`.
    pub fn run(
        self: *AsyncServer,
        comptime Handler: fn (Response, []const u8) void,
    ) !void {
        var pollfds: [MAX_CLIENTS + 1]posix.pollfd = undefined;
        var pfd_to_client: [MAX_CLIENTS]usize = undefined;

        while (self.running) {
            pollfds[0] = .{
                .fd = self.server.socket.handle,
                .events = posix.POLL.IN,
                .revents = 0,
            };
            var pfd_len: usize = 1;

            for (self.clients, 0..) |maybe_s, idx| {
                if (maybe_s) |s| {
                    pollfds[pfd_len] = .{
                        .fd = s.socket.handle,
                        .events = posix.POLL.IN,
                        .revents = 0,
                    };
                    pfd_to_client[pfd_len - 1] = idx;
                    pfd_len += 1;
                }
            }

            const ready = posix.poll(pollfds[0..pfd_len], 100) catch |err| switch (err) {
                error.NetworkDown => continue,
                else => return err,
            };
            if (ready == 0) continue;

            // 1. Accept incoming connection
            if (pollfds[0].revents & posix.POLL.IN != 0) {
                if (self.server.accept(self.io) catch null) |stream| {
                    var slotted = false;
                    for (&self.clients) |*slot| {
                        if (slot.* == null) {
                            slot.* = stream;
                            slotted = true;
                            break;
                        }
                    }
                    if (!slotted) {
                        // Max clients reached
                        stream.close(self.io);
                    }
                }
            }

            // 2. Active client events
            var i: usize = 1;
            while (i < pfd_len) : (i += 1) {
                const revents = pollfds[i].revents;
                if (revents == 0) continue;

                const c_idx = pfd_to_client[i - 1];
                const s = self.clients[c_idx] orelse continue;

                if (revents & posix.POLL.IN != 0) {
                    var rx_buf: [DEFAULT_BUF_SIZE]u8 = undefined;
                    const msg = s.socket.receive(self.io, &rx_buf) catch {
                        s.close(self.io);
                        self.clients[c_idx] = null;
                        continue;
                    };

                    if (msg.data.len == 0) {
                        // Clean EOF disconnect
                        s.close(self.io);
                        self.clients[c_idx] = null;
                        continue;
                    }

                    const resp = Response{ .stream = s, .io = self.io };
                    Handler(resp, msg.data);
                } else if (revents & (posix.POLL.ERR | posix.POLL.HUP) != 0) {
                    s.close(self.io);
                    self.clients[c_idx] = null;
                }
            }
        }
    }
};

test "AsyncServer single-threaded unit test" {
    var single = Io.Threaded.init_single_threaded;
    const io = single.io();

    var server = try AsyncServer.init(io, .{
        .port = 0, // OS assigned ephemeral port
        .address = "127.0.0.1",
    });
    defer server.deinit();

    var bound_addr: std.posix.sockaddr.in = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
    _ = std.posix.system.getsockname(server.server.socket.handle, @ptrCast(&bound_addr), &addr_len);
    const port = std.mem.bigToNative(u16, bound_addr.port);
    const client_addr = try Io.net.IpAddress.parse("127.0.0.1", port);

    const EchoHandler = struct {
        fn handle(res: AsyncServer.Response, msg: []const u8) void {
            res.print("echo:{s}", .{msg}) catch return;
        }
    };

    const SrvThread = struct {
        srv: *AsyncServer,
        fn run(s: *AsyncServer) void {
            s.run(EchoHandler.handle) catch {};
        }
    };
    const thread = try std.Thread.spawn(.{}, SrvThread.run, .{&server});

    // Connect client
    const client = try client_addr.connect(io, .{ .mode = .stream });
    defer client.close(io);

    // Send payload
    {
        var tx: [64]u8 = undefined;
        var writer = Io.net.Stream.Writer.init(client, io, &tx);
        _ = try writer.interface.writeAll("hello_stdx");
        _ = try writer.interface.flush();
    }

    // Receive response
    var rx: [64]u8 = undefined;
    const msg = try client.socket.receive(io, &rx);
    try testing.expectEqualStrings("echo:hello_stdx", msg.data);

    // Stop server and join
    server.stop();
    thread.join();
}
