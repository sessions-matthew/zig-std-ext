//! stdx.rpc: Zero-allocation compile-time RPC generator over arbitrary byte transports.
//!
//! Reflects over API definition structs using Zig's comptime `@typeInfo`.
//! Automatically synthesizes strongly-typed client stubs (`RpcClient(Api)`) and server
//! dispatchers (`RpcDispatcher(Api, Service)`) with zero heap allocations.

const std = @import("std");
const framing = @import("../framing/root.zig");

pub const MSG_RPC_CALL: u8 = 0x50;
pub const MSG_RPC_RESP: u8 = 0x51;

pub const RpcStatus = enum(u8) {
    ok = 0x00,
    method_not_found = 0x01,
    invalid_args = 0x02,
    handler_error = 0x03,
    buffer_overflow = 0x04,
    execution_failed = 0x05,
};

pub const RpcError = error{
    MethodNotFound,
    InvalidArgs,
    HandlerError,
    BufferOverflow,
    ExecutionFailed,
    Timeout,
    UnexpectedEof,
    TransportError,
    InvalidResponse,
    InvalidCrc,
};

// ============================================================================
// 1. Compile-Time Wire Serialization & Deserialization
// ============================================================================

pub fn serializeValue(val: anytype, out: []u8) error{BufferOverflow}!usize {
    const T = @TypeOf(val);
    switch (@typeInfo(T)) {
        .void => return 0,
        .bool => {
            if (out.len < 1) return error.BufferOverflow;
            out[0] = if (val) 1 else 0;
            return 1;
        },
        .int => {
            const size = @sizeOf(T);
            if (out.len < size) return error.BufferOverflow;
            std.mem.writeInt(T, out[0..size], val, .little);
            return size;
        },
        .float => {
            const size = @sizeOf(T);
            if (out.len < size) return error.BufferOverflow;
            const IntType = std.meta.Int(.unsigned, size * 8);
            const int_val: IntType = @bitCast(val);
            std.mem.writeInt(IntType, out[0..size], int_val, .little);
            return size;
        },
        .@"enum" => |e| {
            return serializeValue(@as(e.tag_type, @intFromEnum(val)), out);
        },
        .@"struct" => |s| {
            var offset: usize = 0;
            inline for (s.field_names) |fname| {
                const fval = @field(val, fname);
                offset += try serializeValue(fval, out[offset..]);
            }
            return offset;
        },
        .array => |a| {
            var offset: usize = 0;
            inline for (0..a.len) |i| {
                offset += try serializeValue(val[i], out[offset..]);
            }
            return offset;
        },
        .comptime_int => return serializeValue(@as(i32, val), out),
        .comptime_float => return serializeValue(@as(f32, val), out),
        else => @compileError("Unsupported RPC serialization type: " ++ @typeName(T)),
    }
}

pub fn deserializeValue(comptime T: type, in: []const u8, offset: *usize) error{UnexpectedEof}!T {
    switch (@typeInfo(T)) {
        .void => return {},
        .bool => {
            if (offset.* + 1 > in.len) return error.UnexpectedEof;
            const res = in[offset.*] != 0;
            offset.* += 1;
            return res;
        },
        .int => {
            const size = @sizeOf(T);
            if (offset.* + size > in.len) return error.UnexpectedEof;
            const res = std.mem.readInt(T, in[offset.*..][0..size], .little);
            offset.* += size;
            return res;
        },
        .float => {
            const size = @sizeOf(T);
            if (offset.* + size > in.len) return error.UnexpectedEof;
            const IntType = std.meta.Int(.unsigned, size * 8);
            const int_val = std.mem.readInt(IntType, in[offset.*..][0..size], .little);
            offset.* += size;
            return @bitCast(int_val);
        },
        .@"enum" => |e| {
            const tag = try deserializeValue(e.tag_type, in, offset);
            return std.enums.fromInt(T, tag) orelse error.UnexpectedEof;
        },
        .@"struct" => |s| {
            var result: T = undefined;
            inline for (s.field_names) |fname| {
                const FType = @TypeOf(@field(result, fname));
                @field(result, fname) = try deserializeValue(FType, in, offset);
            }
            return result;
        },
        .array => |a| {
            var result: [a.len]a.child = undefined;
            inline for (0..a.len) |i| {
                result[i] = try deserializeValue(a.child, in, offset);
            }
            return result;
        },
        else => @compileError("Unsupported RPC deserialization type: " ++ @typeName(T)),
    }
}

// ============================================================================
// 2. Transport Abstraction
// ============================================================================

pub const Transport = struct {
    ptr: *anyopaque,
    write_fn: *const fn (ptr: *anyopaque, bytes: []const u8) anyerror!usize,
    read_fn: *const fn (ptr: *anyopaque, buf: []u8) anyerror!usize,

    pub fn write(self: Transport, bytes: []const u8) anyerror!usize {
        return self.write_fn(self.ptr, bytes);
    }

    pub fn read(self: Transport, buf: []u8) anyerror!usize {
        return self.read_fn(self.ptr, buf);
    }

    pub fn from(pointer: anytype) Transport {
        const Ptr = @TypeOf(pointer);
        const PtrInfo = @typeInfo(Ptr);
        if (PtrInfo != .pointer) @compileError("Transport.from requires a pointer argument");

        const gen = struct {
            fn write(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
                const self: Ptr = @ptrCast(@alignCast(ctx));
                return self.write(bytes);
            }

            fn read(ctx: *anyopaque, buf: []u8) anyerror!usize {
                const self: Ptr = @ptrCast(@alignCast(ctx));
                return self.read(buf);
            }
        };

        return .{
            .ptr = pointer,
            .write_fn = gen.write,
            .read_fn = gen.read,
        };
    }
};

/// In-memory ring buffer FIFO for testing and local IPC.
pub const Fifo = struct {
    buf: [1024]u8 = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    pub fn init() Fifo {
        return .{};
    }

    pub fn write(self: *Fifo, bytes: []const u8) anyerror!usize {
        var written: usize = 0;
        for (bytes) |b| {
            if (self.count >= self.buf.len) break;
            self.buf[self.tail] = b;
            self.tail = (self.tail + 1) % self.buf.len;
            self.count += 1;
            written += 1;
        }
        return written;
    }

    pub fn read(self: *Fifo, out: []u8) anyerror!usize {
        var read_bytes: usize = 0;
        while (read_bytes < out.len and self.count > 0) {
            out[read_bytes] = self.buf[self.head];
            self.head = (self.head + 1) % self.buf.len;
            self.count -= 1;
            read_bytes += 1;
        }
        return read_bytes;
    }
};

/// Bidirectional in-memory transport connecting client and server.
pub const DuplexFifo = struct {
    c2s: Fifo = Fifo.init(),
    s2c: Fifo = Fifo.init(),
    pump_ctx: ?*anyopaque = null,
    pump_fn: ?*const fn (ctx: *anyopaque, duplex: *DuplexFifo) anyerror!void = null,

    pub fn init() DuplexFifo {
        return .{};
    }

    pub const ClientEndpoint = struct {
        fifo: *DuplexFifo,

        pub fn write(self: *ClientEndpoint, bytes: []const u8) anyerror!usize {
            const written = try self.fifo.c2s.write(bytes);
            if (self.fifo.pump_fn) |pfn| {
                if (self.fifo.pump_ctx) |ctx| {
                    try pfn(ctx, self.fifo);
                }
            }
            return written;
        }

        pub fn read(self: *ClientEndpoint, buf: []u8) anyerror!usize {
            return self.fifo.s2c.read(buf);
        }
    };

    pub const ServerEndpoint = struct {
        fifo: *DuplexFifo,

        pub fn write(self: *ServerEndpoint, bytes: []const u8) anyerror!usize {
            return self.fifo.s2c.write(bytes);
        }

        pub fn read(self: *ServerEndpoint, buf: []u8) anyerror!usize {
            return self.fifo.c2s.read(buf);
        }
    };

    pub fn clientEndpoint(self: *DuplexFifo) ClientEndpoint {
        return .{ .fifo = self };
    }

    pub fn serverEndpoint(self: *DuplexFifo) ServerEndpoint {
        return .{ .fifo = self };
    }

    pub fn attachDispatcher(self: *DuplexFifo, comptime DispatcherType: type, dispatcher: *DispatcherType) void {
        const helper = struct {
            fn pump(ctx: *anyopaque, duplex: *DuplexFifo) anyerror!void {
                const disp: *DispatcherType = @ptrCast(@alignCast(ctx));
                var ep = duplex.serverEndpoint();
                var byte_buf: [1]u8 = undefined;
                while (try ep.read(&byte_buf) > 0) {
                    _ = try disp.feedByte(byte_buf[0], &ep);
                }
            }
        };
        self.pump_ctx = dispatcher;
        self.pump_fn = helper.pump;
    }
};

// ============================================================================
// 3. API Reflection
// ============================================================================

pub fn ApiMetadata(comptime Api: type) type {
    const s_info = @typeInfo(Api).@"struct";
    return struct {
        pub const method_count = s_info.field_names.len;

        pub fn getMethodIndex(comptime name: []const u8) ?u8 {
            inline for (s_info.field_names, 0..) |fname, idx| {
                if (comptime std.mem.eql(u8, fname, name)) {
                    return @intCast(idx);
                }
            }
            return null;
        }

        pub fn getMethodName(comptime idx: u8) []const u8 {
            return s_info.field_names[idx];
        }

        pub fn MethodType(comptime idx: u8) type {
            return s_info.field_types[idx];
        }

        pub fn ReturnType(comptime idx: u8) type {
            const T = MethodType(idx);
            const fn_info = switch (@typeInfo(T)) {
                .@"fn" => |f| f,
                .pointer => |p| @typeInfo(p.child).@"fn",
                else => @compileError("API field must be a function: " ++ getMethodName(idx)),
            };
            const raw_ret = fn_info.return_type orelse void;
            return switch (@typeInfo(raw_ret)) {
                .error_union => |eu| eu.payload,
                else => raw_ret,
            };
        }

        pub fn ParamTypes(comptime idx: u8) []const ?type {
            const T = MethodType(idx);
            const fn_info = switch (@typeInfo(T)) {
                .@"fn" => |f| f,
                .pointer => |p| @typeInfo(p.child).@"fn",
                else => @compileError("API field must be a function: " ++ getMethodName(idx)),
            };
            return fn_info.param_types;
        }
    };
}

// ============================================================================
// 4. Compile-Time RPC Client
// ============================================================================

pub fn RpcClient(comptime Api: type) type {
    const Meta = ApiMetadata(Api);

    return struct {
        const Self = @This();

        transport: Transport,
        parser: framing.StreamParser = framing.StreamParser.init(),
        max_retries: usize = 100,

        pub fn init(transport_impl: anytype) Self {
            return .{
                .transport = Transport.from(transport_impl),
            };
        }

        /// Universal reflection-driven RPC invocation
        pub fn call(self: *Self, comptime method_name: []const u8, args: anytype) !Meta.ReturnType(Meta.getMethodIndex(method_name) orelse @compileError("Method not found in API: " ++ method_name)) {
            const method_idx = comptime (Meta.getMethodIndex(method_name) orelse @compileError("Unknown method: " ++ method_name));
            const RetType = comptime Meta.ReturnType(method_idx);
            const expected_params = comptime Meta.ParamTypes(method_idx);

            // 1. Pack method ID and serialized arguments
            var payload_buf: [framing.MAX_PAYLOAD_LEN]u8 = undefined;
            payload_buf[0] = method_idx;
            var payload_len: usize = 1;

            const ArgsType = @TypeOf(args);
            const args_info = @typeInfo(ArgsType);
            const num_args = if (args_info == .@"struct" and args_info.@"struct".is_tuple)
                args_info.@"struct".field_names.len
            else
                0;

            if (num_args != expected_params.len) {
                @compileError("Argument count mismatch for " ++ method_name);
            }

            inline for (0..num_args) |arg_idx| {
                const PType = expected_params[arg_idx].?;
                const arg_val: PType = args[arg_idx];
                const written = try serializeValue(arg_val, payload_buf[payload_len..]);
                payload_len += written;
            }

            // 2. Frame and transmit packet
            var frame_buf: [framing.MAX_PAYLOAD_LEN + framing.FRAME_OVERHEAD]u8 = undefined;
            const frame_len = framing.serializePacket(MSG_RPC_CALL, payload_buf[0..payload_len], &frame_buf);
            if (frame_len == 0) return error.BufferOverflow;

            _ = try self.transport.write(frame_buf[0..frame_len]);

            // 3. Receive and parse response
            var retries: usize = 0;
            self.parser.reset();

            while (retries < self.max_retries) : (retries += 1) {
                var rx_buf: [64]u8 = undefined;
                const read_bytes = try self.transport.read(&rx_buf);
                if (read_bytes == 0) continue;

                for (rx_buf[0..read_bytes]) |b| {
                    if (self.parser.feed(b)) |pkt| {
                        if (pkt.msg_id != MSG_RPC_RESP) continue;

                        const resp_payload = pkt.getPayload();
                        if (resp_payload.len < 2) return error.InvalidResponse;

                        const resp_method_idx = resp_payload[0];
                        if (resp_method_idx != method_idx) continue;

                        const status_byte = resp_payload[1];
                        const status: RpcStatus = std.enums.fromInt(RpcStatus, status_byte) orelse return error.InvalidResponse;

                        switch (status) {
                            .ok => {
                                if (RetType == void) return {};
                                var offset: usize = 2;
                                return try deserializeValue(RetType, resp_payload, &offset);
                            },
                            .method_not_found => return error.MethodNotFound,
                            .invalid_args => return error.InvalidArgs,
                            .handler_error => return error.HandlerError,
                            .buffer_overflow => return error.BufferOverflow,
                            .execution_failed => return error.ExecutionFailed,
                        }
                    }
                }
            }

            return error.Timeout;
        }
    };
}

// ============================================================================
// 5. Compile-Time RPC Dispatcher
// ============================================================================

pub fn RpcDispatcher(comptime Api: type, comptime Service: type) type {
    const Meta = ApiMetadata(Api);

    return struct {
        const Self = @This();

        service: *Service,
        parser: framing.StreamParser = framing.StreamParser.init(),

        pub fn init(service: *Service) Self {
            return .{ .service = service };
        }

        pub fn dispatch(self: *Self, call_payload: []const u8, out_buf: []u8) usize {
            if (call_payload.len < 1) return 0;
            const method_idx = call_payload[0];

            if (method_idx >= Meta.method_count) {
                return self.buildErrorResponse(method_idx, .method_not_found, out_buf);
            }

            inline for (0..Meta.method_count) |idx| {
                if (method_idx == idx) {
                    return self.dispatchMethod(idx, call_payload[1..], out_buf);
                }
            }
            return 0;
        }

        fn dispatchMethod(self: *Self, comptime method_idx: u8, args_payload: []const u8, out_buf: []u8) usize {
            const method_name = comptime Meta.getMethodName(method_idx);
            const RetType = comptime Meta.ReturnType(method_idx);
            const param_types = comptime Meta.ParamTypes(method_idx);

            var in_offset: usize = 0;
            var resp_payload: [framing.MAX_PAYLOAD_LEN]u8 = undefined;
            resp_payload[0] = method_idx;
            var out_offset: usize = 2;

            if (param_types.len == 0) {
                const call_res = self.invokeMethod(method_name, .{});
                if (RetType == void) {
                    if (call_res) |_| {
                        resp_payload[1] = @intFromEnum(RpcStatus.ok);
                    } else |_| {
                        resp_payload[1] = @intFromEnum(RpcStatus.handler_error);
                    }
                } else {
                    if (call_res) |res| {
                        resp_payload[1] = @intFromEnum(RpcStatus.ok);
                        const written = serializeValue(res, resp_payload[out_offset..]) catch {
                            return self.buildErrorResponse(method_idx, .buffer_overflow, out_buf);
                        };
                        out_offset += written;
                    } else |_| {
                        resp_payload[1] = @intFromEnum(RpcStatus.handler_error);
                    }
                }
            } else if (param_types.len == 1) {
                const P0 = param_types[0].?;
                const p0_val = deserializeValue(P0, args_payload, &in_offset) catch {
                    return self.buildErrorResponse(method_idx, .invalid_args, out_buf);
                };
                const call_res = self.invokeMethod(method_name, .{p0_val});
                if (RetType == void) {
                    if (call_res) |_| {
                        resp_payload[1] = @intFromEnum(RpcStatus.ok);
                    } else |_| {
                        resp_payload[1] = @intFromEnum(RpcStatus.handler_error);
                    }
                } else {
                    if (call_res) |res| {
                        resp_payload[1] = @intFromEnum(RpcStatus.ok);
                        const written = serializeValue(res, resp_payload[out_offset..]) catch {
                            return self.buildErrorResponse(method_idx, .buffer_overflow, out_buf);
                        };
                        out_offset += written;
                    } else |_| {
                        resp_payload[1] = @intFromEnum(RpcStatus.handler_error);
                    }
                }
            } else if (param_types.len == 2) {
                const P0 = param_types[0].?;
                const P1 = param_types[1].?;
                const p0_val = deserializeValue(P0, args_payload, &in_offset) catch {
                    return self.buildErrorResponse(method_idx, .invalid_args, out_buf);
                };
                const p1_val = deserializeValue(P1, args_payload, &in_offset) catch {
                    return self.buildErrorResponse(method_idx, .invalid_args, out_buf);
                };
                const call_res = self.invokeMethod(method_name, .{ p0_val, p1_val });
                if (RetType == void) {
                    if (call_res) |_| {
                        resp_payload[1] = @intFromEnum(RpcStatus.ok);
                    } else |_| {
                        resp_payload[1] = @intFromEnum(RpcStatus.handler_error);
                    }
                } else {
                    if (call_res) |res| {
                        resp_payload[1] = @intFromEnum(RpcStatus.ok);
                        const written = serializeValue(res, resp_payload[out_offset..]) catch {
                            return self.buildErrorResponse(method_idx, .buffer_overflow, out_buf);
                        };
                        out_offset += written;
                    } else |_| {
                        resp_payload[1] = @intFromEnum(RpcStatus.handler_error);
                    }
                }
            } else if (param_types.len == 3) {
                const P0 = param_types[0].?;
                const P1 = param_types[1].?;
                const P2 = param_types[2].?;
                const p0_val = deserializeValue(P0, args_payload, &in_offset) catch {
                    return self.buildErrorResponse(method_idx, .invalid_args, out_buf);
                };
                const p1_val = deserializeValue(P1, args_payload, &in_offset) catch {
                    return self.buildErrorResponse(method_idx, .invalid_args, out_buf);
                };
                const p2_val = deserializeValue(P2, args_payload, &in_offset) catch {
                    return self.buildErrorResponse(method_idx, .invalid_args, out_buf);
                };
                const call_res = self.invokeMethod(method_name, .{ p0_val, p1_val, p2_val });
                if (RetType == void) {
                    if (call_res) |_| {
                        resp_payload[1] = @intFromEnum(RpcStatus.ok);
                    } else |_| {
                        resp_payload[1] = @intFromEnum(RpcStatus.handler_error);
                    }
                } else {
                    if (call_res) |res| {
                        resp_payload[1] = @intFromEnum(RpcStatus.ok);
                        const written = serializeValue(res, resp_payload[out_offset..]) catch {
                            return self.buildErrorResponse(method_idx, .buffer_overflow, out_buf);
                        };
                        out_offset += written;
                    } else |_| {
                        resp_payload[1] = @intFromEnum(RpcStatus.handler_error);
                    }
                }
            } else {
                @compileError("RPC methods with more than 3 parameters not currently supported");
            }

            return framing.serializePacket(MSG_RPC_RESP, resp_payload[0..out_offset], out_buf);
        }

        fn invokeMethod(self: *Self, comptime method_name: []const u8, args: anytype) anyerror!ReturnTypeOf(Service, method_name) {
            const func = @field(Service, method_name);
            const fn_info = @typeInfo(@TypeOf(func)).@"fn";

            if (fn_info.param_types.len > 0 and (fn_info.param_types[0].? == *Service or fn_info.param_types[0].? == Service or fn_info.param_types[0].? == *const Service)) {
                return @call(.auto, func, .{self.service} ++ args);
            } else {
                return @call(.auto, func, args);
            }
        }

        fn buildErrorResponse(_: *Self, method_idx: u8, status: RpcStatus, out_buf: []u8) usize {
            const resp = [_]u8{ method_idx, @intFromEnum(status) };
            return framing.serializePacket(MSG_RPC_RESP, &resp, out_buf);
        }

        pub fn feedByte(self: *Self, byte: u8, reply_transport: anytype) !bool {
            if (self.parser.feed(byte)) |pkt| {
                if (pkt.msg_id == MSG_RPC_CALL) {
                    var out_frame: [framing.MAX_PAYLOAD_LEN + framing.FRAME_OVERHEAD]u8 = undefined;
                    const len = self.dispatch(pkt.getPayload(), &out_frame);
                    if (len > 0) {
                        _ = try reply_transport.write(out_frame[0..len]);
                    }
                    return true;
                }
            }
            return false;
        }
    };
}

fn ReturnTypeOf(comptime Target: type, comptime name: []const u8) type {
    const func = @field(Target, name);
    const fn_info = @typeInfo(@TypeOf(func)).@"fn";
    const raw_ret = fn_info.return_type orelse void;
    return switch (@typeInfo(raw_ret)) {
        .error_union => |eu| eu.payload,
        else => raw_ret,
    };
}

// ============================================================================
// Unit Tests
// ============================================================================

const SampleApi = struct {
    add: fn (a: i32, b: i32) i32,
    divide: fn (a: i32, b: i32) i32,
    status: fn () u8,
};

const SampleService = struct {
    calls: u32 = 0,

    pub fn add(self: *SampleService, a: i32, b: i32) i32 {
        self.calls += 1;
        return a + b;
    }

    pub fn divide(self: *SampleService, a: i32, b: i32) !i32 {
        self.calls += 1;
        if (b == 0) return error.DivisionByZero;
        return @divTrunc(a, b);
    }

    pub fn status(self: *SampleService) u8 {
        self.calls += 1;
        return 42;
    }
};

test "rpc: client/server roundtrip over DuplexFifo" {
    var duplex = DuplexFifo.init();
    var service = SampleService{};

    var dispatcher = RpcDispatcher(SampleApi, SampleService).init(&service);
    duplex.attachDispatcher(RpcDispatcher(SampleApi, SampleService), &dispatcher);

    var client_ep = duplex.clientEndpoint();
    var client = RpcClient(SampleApi).init(&client_ep);

    // Call add
    const sum = try client.call("add", .{ 15, 27 });
    try std.testing.expectEqual(@as(i32, 42), sum);

    // Call divide (success)
    const div = try client.call("divide", .{ 100, 5 });
    try std.testing.expectEqual(@as(i32, 20), div);

    // Call divide (error union propagation)
    const div_err = client.call("divide", .{ 10, 0 });
    try std.testing.expectError(error.HandlerError, div_err);

    // Call status (no arguments)
    const st = try client.call("status", .{});
    try std.testing.expectEqual(@as(u8, 42), st);

    try std.testing.expectEqual(@as(u32, 4), service.calls);
}
