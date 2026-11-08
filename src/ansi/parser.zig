//! stdx.ansi: Zero-allocation ANSI / VT100 escape sequence parser, stripper, and visible-width calculator.
//!
//! Handles standard CSI (Control Sequence Introducer), SGR styling (16-color, 256-color, 24-bit RGB),
//! OSC (Operating System Command), and cursor/screen control sequences with zero heap allocations.

const std = @import("std");

pub const State = enum {
    ground,
    esc,
    csi,
    osc,
};

pub const Csi = struct {
    command: u8,
    private_prefix: ?u8 = null,
    params: [16]u16 = @splat(0),
    param_count: usize = 0,

    /// Retrieves parameter at `idx`, or returns `default_val` if omitted or out of bounds.
    pub fn getParam(self: *const Csi, idx: usize, default_val: u16) u16 {
        if (idx < self.param_count and self.params[idx] != 0) {
            return self.params[idx];
        }
        return default_val;
    }
};

pub const TokenType = enum {
    text,
    csi,
    osc,
    control,
};

pub const Token = union(TokenType) {
    text: []const u8,
    csi: Csi,
    osc: []const u8,
    control: u8,
};

/// Computes the terminal column width of a string, completely ignoring ANSI escape codes.
pub fn visibleWidth(input: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        const b = input[i];

        if (b == 0x1b) {
            // ESC sequence
            i += 1;
            if (i >= input.len) break;
            const next = input[i];
            if (next == '[') {
                // CSI: skip until terminating character (0x40 - 0x7E)
                i += 1;
                while (i < input.len) : (i += 1) {
                    const c = input[i];
                    if (c >= 0x40 and c <= 0x7e) {
                        i += 1;
                        break;
                    }
                }
            } else if (next == ']') {
                // OSC: skip until BEL (0x07) or ST (\x1b\)
                i += 1;
                while (i < input.len) : (i += 1) {
                    if (input[i] == 0x07) {
                        i += 1;
                        break;
                    }
                    if (input[i] == 0x1b and i + 1 < input.len and input[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                }
            } else {
                i += 1;
            }
            continue;
        }

        // C0 control characters (skip bell, bs, newline, cr; treat tab as 4-space equivalent or 1)
        if (b < 0x20) {
            if (b == '\t') {
                width += 4;
            }
            i += 1;
            continue;
        }

        // UTF-8 lead byte check
        const seq_len = std.unicode.utf8ByteSequenceLength(b) catch 1;
        width += 1;
        i += seq_len;
    }

    return width;
}

/// Strips all ANSI escape sequences from `input` into `out_buf`.
/// Returns the slice of `out_buf` containing the clean text.
pub fn strip(input: []const u8, out_buf: []u8) []const u8 {
    var out_idx: usize = 0;
    var i: usize = 0;

    while (i < input.len and out_idx < out_buf.len) {
        const b = input[i];

        if (b == 0x1b) {
            i += 1;
            if (i >= input.len) break;
            const next = input[i];
            if (next == '[') {
                i += 1;
                while (i < input.len) : (i += 1) {
                    const c = input[i];
                    if (c >= 0x40 and c <= 0x7e) {
                        i += 1;
                        break;
                    }
                }
            } else if (next == ']') {
                i += 1;
                while (i < input.len) : (i += 1) {
                    if (input[i] == 0x07) {
                        i += 1;
                        break;
                    }
                    if (input[i] == 0x1b and i + 1 < input.len and input[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                }
            } else {
                i += 1;
            }
            continue;
        }

        out_buf[out_idx] = b;
        out_idx += 1;
        i += 1;
    }

    return out_buf[0..out_idx];
}

/// Allocating version of `strip`.
pub fn stripAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, input.len);
    errdefer allocator.free(buf);
    const slice = strip(input, buf);
    if (slice.len == input.len) return buf;
    return try allocator.realloc(buf, slice.len);
}

/// Token stream iterator over ANSI text.
pub const Iterator = struct {
    src: []const u8,
    pos: usize = 0,

    pub fn init(src: []const u8) Iterator {
        return .{ .src = src, .pos = 0 };
    }

    pub fn next(self: *Iterator) ?Token {
        if (self.pos >= self.src.len) return null;

        const b = self.src[self.pos];

        if (b == 0x1b) {
            // Escape sequence
            if (self.pos + 1 >= self.src.len) {
                self.pos += 1;
                return .{ .control = 0x1b };
            }

            const next_b = self.src[self.pos + 1];
            if (next_b == '[') {
                // Parse CSI
                self.pos += 2;
                var csi = Csi{ .command = 0 };
                if (self.pos < self.src.len and (self.src[self.pos] == '?' or self.src[self.pos] == '>')) {
                    csi.private_prefix = self.src[self.pos];
                    self.pos += 1;
                }

                var cur_val: u16 = 0;
                var has_val = false;

                while (self.pos < self.src.len) : (self.pos += 1) {
                    const c = self.src[self.pos];
                    if (c >= '0' and c <= '9') {
                        cur_val = cur_val * 10 + (c - '0');
                        has_val = true;
                    } else if (c == ';') {
                        if (csi.param_count < 16) {
                            csi.params[csi.param_count] = cur_val;
                            csi.param_count += 1;
                        }
                        cur_val = 0;
                        has_val = false;
                    } else if (c >= 0x40 and c <= 0x7e) {
                        // Final terminating command byte
                        if (has_val and csi.param_count < 16) {
                            csi.params[csi.param_count] = cur_val;
                            csi.param_count += 1;
                        }
                        csi.command = c;
                        self.pos += 1;
                        return .{ .csi = csi };
                    }
                }
                return .{ .csi = csi };
            } else if (next_b == ']') {
                // Parse OSC
                const start = self.pos + 2;
                self.pos += 2;
                while (self.pos < self.src.len) : (self.pos += 1) {
                    if (self.src[self.pos] == 0x07) {
                        const payload = self.src[start..self.pos];
                        self.pos += 1;
                        return .{ .osc = payload };
                    }
                    if (self.src[self.pos] == 0x1b and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\\') {
                        const payload = self.src[start..self.pos];
                        self.pos += 2;
                        return .{ .osc = payload };
                    }
                }
                return .{ .osc = self.src[start..self.pos] };
            } else {
                self.pos += 2;
                return .{ .control = next_b };
            }
        }

        // C0 control character
        if (b < 0x20 and b != '\t') {
            self.pos += 1;
            return .{ .control = b };
        }

        // Text slice
        const text_start = self.pos;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == 0x1b or (c < 0x20 and c != '\t')) break;
            self.pos += 1;
        }

        return .{ .text = self.src[text_start..self.pos] };
    }
};

test "ansi.parser: visibleWidth calculations" {
    const raw = "\x1b[31;1mError:\x1b[0m File not found!";
    try std.testing.expectEqual(@as(usize, 22), visibleWidth(raw));

    const osc_raw = "\x1b]0;My Window\x07Visible Content";
    try std.testing.expectEqual(@as(usize, 15), visibleWidth(osc_raw));
}

test "ansi.parser: strip escape sequences" {
    const raw = "\x1b[1;32mSUCCESS:\x1b[0m Build passed in \x1b[33m120ms\x1b[0m\n";
    var buf: [128]u8 = undefined;
    const clean = strip(raw, &buf);
    try std.testing.expectEqualStrings("SUCCESS: Build passed in 120ms\n", clean);
}

test "ansi.parser: iterator tokens" {
    const input = "\x1b[38;2;255;0;128mRGB Text\x1b[0m";
    var it = Iterator.init(input);

    const tok1 = it.next().?;
    try std.testing.expectEqual(TokenType.csi, @as(TokenType, tok1));
    try std.testing.expectEqual(@as(u8, 'm'), tok1.csi.command);
    try std.testing.expectEqual(@as(usize, 5), tok1.csi.param_count);
    try std.testing.expectEqual(@as(u16, 38), tok1.csi.params[0]);
    try std.testing.expectEqual(@as(u16, 2), tok1.csi.params[1]);
    try std.testing.expectEqual(@as(u16, 255), tok1.csi.params[2]);
    try std.testing.expectEqual(@as(u16, 0), tok1.csi.params[3]);
    try std.testing.expectEqual(@as(u16, 128), tok1.csi.params[4]);

    const tok2 = it.next().?;
    try std.testing.expectEqual(TokenType.text, @as(TokenType, tok2));
    try std.testing.expectEqualStrings("RGB Text", tok2.text);

    const tok3 = it.next().?;
    try std.testing.expectEqual(TokenType.csi, @as(TokenType, tok3));
    try std.testing.expectEqual(@as(u8, 'm'), tok3.csi.command);
    try std.testing.expectEqual(@as(u16, 0), tok3.csi.getParam(0, 0));

    try std.testing.expect(it.next() == null);
}
