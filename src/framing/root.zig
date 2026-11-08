//! stdx.framing: Zero-allocation streaming packet framing and serialization.
//!
//! Provides a byte-by-byte streaming state machine parser and serializer
//! with preamble/noise resilience and CRC-16/CCITT-FALSE verification:
//! `[SOF (0xAA)] [MSG_ID (1B)] [LEN (1B)] [PAYLOAD (0..255B)] [CRC16_HI] [CRC16_LO]`

const std = @import("std");
const crc = @import("../crc/root.zig");

pub const SOF: u8 = 0xAA;
pub const MAX_PAYLOAD_LEN: usize = 256;
pub const FRAME_OVERHEAD: usize = 5; // SOF + MSG_ID + LEN + CRC_HI + CRC_LO

pub const Packet = struct {
    msg_id: u8,
    len: u8,
    payload: [MAX_PAYLOAD_LEN]u8 = undefined,

    pub inline fn getPayload(self: *const Packet) []const u8 {
        return self.payload[0..self.len];
    }
};

/// Computes CRC-16 over packet header (msg_id, len) and payload.
pub fn computePacketCrc(msg_id: u8, payload: []const u8) u16 {
    var c = crc.CRC16_CCITT_FALSE_INIT;
    c = crc.updateCrc16CcittFalse(c, msg_id);
    c = crc.updateCrc16CcittFalse(c, @intCast(payload.len));
    for (payload) |b| {
        c = crc.updateCrc16CcittFalse(c, b);
    }
    return c;
}

/// Serializes a message into raw frame bytes.
/// Returns number of bytes written, or 0 if output buffer is too small.
pub fn serializePacket(msg_id: u8, payload: []const u8, out_buf: []u8) usize {
    const total_len = FRAME_OVERHEAD + payload.len;
    if (out_buf.len < total_len or payload.len > MAX_PAYLOAD_LEN) return 0;

    out_buf[0] = SOF;
    out_buf[1] = msg_id;
    out_buf[2] = @intCast(payload.len);

    if (payload.len > 0) {
        @memcpy(out_buf[3 .. 3 + payload.len], payload);
    }

    const calc_crc = computePacketCrc(msg_id, payload);
    const crc_pos = 3 + payload.len;
    out_buf[crc_pos] = @intCast((calc_crc >> 8) & 0xFF);
    out_buf[crc_pos + 1] = @intCast(calc_crc & 0xFF);

    return total_len;
}

/// Non-blocking, streaming byte-by-byte parser.
pub const StreamParser = struct {
    pub const State = enum {
        wait_sof,
        read_id,
        read_len,
        read_payload,
        read_crc_hi,
        read_crc_lo,
    };

    state: State = .wait_sof,
    msg_id: u8 = 0,
    len: u8 = 0,
    bytes_read: usize = 0,
    payload: [MAX_PAYLOAD_LEN]u8 = undefined,
    crc_hi: u8 = 0,
    calculated_crc: u16 = crc.CRC16_CCITT_FALSE_INIT,

    pub fn init() StreamParser {
        return .{};
    }

    pub fn reset(self: *StreamParser) void {
        self.state = .wait_sof;
        self.msg_id = 0;
        self.len = 0;
        self.bytes_read = 0;
        self.calculated_crc = crc.CRC16_CCITT_FALSE_INIT;
    }

    pub inline fn isWaitingSof(self: *const StreamParser) bool {
        return self.state == .wait_sof;
    }

    /// Feed one byte into the streaming parser.
    /// Returns a Packet when a full valid frame with correct CRC is completed.
    pub fn feed(self: *StreamParser, byte: u8) ?Packet {
        switch (self.state) {
            .wait_sof => {
                if (byte == SOF) {
                    self.calculated_crc = crc.CRC16_CCITT_FALSE_INIT;
                    self.state = .read_id;
                }
            },
            .read_id => {
                if (byte == SOF) {
                    // Preamble resilience: repeated SOF bytes reset start of header
                    self.calculated_crc = crc.CRC16_CCITT_FALSE_INIT;
                    return null;
                }
                self.msg_id = byte;
                self.calculated_crc = crc.updateCrc16CcittFalse(self.calculated_crc, byte);
                self.state = .read_len;
            },
            .read_len => {
                self.len = byte;
                self.calculated_crc = crc.updateCrc16CcittFalse(self.calculated_crc, byte);
                self.bytes_read = 0;

                if (self.len == 0) {
                    self.state = .read_crc_hi;
                } else {
                    self.state = .read_payload;
                }
            },
            .read_payload => {
                self.payload[self.bytes_read] = byte;
                self.calculated_crc = crc.updateCrc16CcittFalse(self.calculated_crc, byte);
                self.bytes_read += 1;

                if (self.bytes_read >= self.len) {
                    self.state = .read_crc_hi;
                }
            },
            .read_crc_hi => {
                self.crc_hi = byte;
                self.state = .read_crc_lo;
            },
            .read_crc_lo => {
                const expected_crc = (@as(u16, self.crc_hi) << 8) | @as(u16, byte);
                const is_valid = (expected_crc == self.calculated_crc);

                defer self.reset();

                if (is_valid) {
                    var pkt: Packet = .{
                        .msg_id = self.msg_id,
                        .len = self.len,
                    };
                    @memcpy(pkt.payload[0..self.len], self.payload[0..self.len]);
                    return pkt;
                }
            },
        }
        return null;
    }
};

test "framing: round-trip serialization and stream parser" {
    var out_buf: [64]u8 = undefined;
    const test_payload = [_]u8{ 0x11, 0x22, 0x33, 0x44 };

    const frame_len = serializePacket(0x05, &test_payload, &out_buf);
    try std.testing.expectEqual(@as(usize, 4 + FRAME_OVERHEAD), frame_len);

    var parser = StreamParser.init();
    var received: ?Packet = null;

    for (out_buf[0..frame_len]) |b| {
        if (parser.feed(b)) |pkt| {
            received = pkt;
        }
    }

    try std.testing.expect(received != null);
    try std.testing.expectEqual(@as(u8, 0x05), received.?.msg_id);
    try std.testing.expectEqual(@as(u8, 4), received.?.len);
    try std.testing.expectEqualSlices(u8, &test_payload, received.?.getPayload());
}

test "framing: noise recovery and preamble resilience" {
    var out_buf: [64]u8 = undefined;
    const test_payload = [_]u8{ 0xCA, 0xFE };
    const frame_len = serializePacket(0x10, &test_payload, &out_buf);

    var parser = StreamParser.init();

    // Send noisy garbage followed by multiple SOF preambles
    const noise = [_]u8{ 0xFF, 0x00, 0x55, 0x12, SOF, SOF, SOF };
    for (noise) |b| {
        _ = parser.feed(b);
    }

    // Now feed actual valid frame
    var received: ?Packet = null;
    for (out_buf[0..frame_len]) |b| {
        if (parser.feed(b)) |pkt| {
            received = pkt;
        }
    }

    try std.testing.expect(received != null);
    try std.testing.expectEqual(@as(u8, 0x10), received.?.msg_id);
    try std.testing.expectEqualSlices(u8, &test_payload, received.?.getPayload());
}

test "framing: corrupt CRC rejection" {
    var out_buf: [64]u8 = undefined;
    const test_payload = [_]u8{ 0x01, 0x02, 0x03 };
    const frame_len = serializePacket(0x20, &test_payload, &out_buf);

    // Corrupt one payload byte
    out_buf[4] ^= 0xFF;

    var parser = StreamParser.init();
    var received: ?Packet = null;
    for (out_buf[0..frame_len]) |b| {
        if (parser.feed(b)) |pkt| {
            received = pkt;
        }
    }

    try std.testing.expect(received == null);
}
