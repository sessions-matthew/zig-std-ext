//! stdx.ansi: ANSI escape sequence parser, stripper, visible-width calculator, and SGR style formatter.

const parser = @import("parser.zig");
const style = @import("style.zig");

pub const State = parser.State;
pub const Csi = parser.Csi;
pub const TokenType = parser.TokenType;
pub const Token = parser.Token;
pub const visibleWidth = parser.visibleWidth;
pub const strip = parser.strip;
pub const stripAlloc = parser.stripAlloc;
pub const Iterator = parser.Iterator;

pub const BasicColor = style.BasicColor;
pub const Color = style.Color;
pub const Style = style.Style;

test {
    @import("std").testing.refAllDecls(@This());
    _ = parser;
    _ = style;
}
