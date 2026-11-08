//! stdx.ansi.style: SGR (Select Graphic Rendition) styling and color formatting.

const std = @import("std");

pub const BasicColor = enum(u8) {
    black = 30,
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
    white = 37,
    bright_black = 90,
    bright_red = 91,
    bright_green = 92,
    bright_yellow = 93,
    bright_blue = 94,
    bright_magenta = 95,
    bright_cyan = 96,
    bright_white = 97,
};

pub const Color = union(enum) {
    basic: BasicColor,
    indexed: u8,
    rgb: struct { r: u8, g: u8, b: u8 },

    pub fn writeForeground(self: Color, writer: anytype) !void {
        switch (self) {
            .basic => |b| try writer.print("\x1b[{d}m", .{@intFromEnum(b)}),
            .indexed => |idx| try writer.print("\x1b[38;5;{d}m", .{idx}),
            .rgb => |rgb| try writer.print("\x1b[38;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b }),
        }
    }

    pub fn writeBackground(self: Color, writer: anytype) !void {
        switch (self) {
            .basic => |b| {
                const code = @intFromEnum(b);
                const bg_code = if (code >= 90) code + 10 else code + 10;
                try writer.print("\x1b[{d}m", .{bg_code});
            },
            .indexed => |idx| try writer.print("\x1b[48;5;{d}m", .{idx}),
            .rgb => |rgb| try writer.print("\x1b[48;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b }),
        }
    }
};

pub const Style = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    inverse: bool = false,

    pub const reset_seq = "\x1b[0m";

    pub fn writePrefix(self: Style, writer: anytype) !void {
        if (self.bold) try writer.writeAll("\x1b[1m");
        if (self.dim) try writer.writeAll("\x1b[2m");
        if (self.italic) try writer.writeAll("\x1b[3m");
        if (self.underline) try writer.writeAll("\x1b[4m");
        if (self.inverse) try writer.writeAll("\x1b[7m");

        if (self.fg) |fg| try fg.writeForeground(writer);
        if (self.bg) |bg| try bg.writeBackground(writer);
    }

    pub fn writeSuffix(_: Style, writer: anytype) !void {
        try writer.writeAll(reset_seq);
    }
};

test "ansi.style: write color codes" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();

    const style = Style{
        .bold = true,
        .fg = .{ .basic = .red },
    };

    try style.writePrefix(&aw.writer);
    try aw.writer.writeAll("Error");
    try style.writeSuffix(&aw.writer);

    try std.testing.expectEqualStrings("\x1b[1m\x1b[31mError\x1b[0m", aw.writer.buffer[0..aw.writer.end]);
}
