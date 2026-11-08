const std = @import("std");
const stdx = @import("stdx");

fn handleClient(res: stdx.net.Response, msg: []const u8) void {
    std.debug.print("Client message: {s}\n", .{msg});
    res.print("echo from stdx: {s}\n", .{msg}) catch return;
}

pub fn main() !void {
    var single = std.Io.Threaded.init_single_threaded;
    const io = single.io();

    var server = try stdx.net.AsyncServer.init(io, .{
        .port = 8080,
        .address = "127.0.0.1",
    });
    defer server.deinit();

    std.debug.print("stdx Echo Server listening on 127.0.0.1:8080 (Single-Threaded)\n", .{});
    try server.run(handleClient);
}
