//! stdx.crc: High-performance Cyclic Redundancy Check (CRC) engines.
//!
//! Provides bitwise and table-driven CRC algorithms commonly used in telecommunications,
//! networking, framing protocols, and embedded hardware interfaces.

const std = @import("std");

// ============================================================================
// CRC-16 / CCITT-FALSE (Polynomial 0x1021, Init 0xFFFF)
// ============================================================================

pub const CRC16_CCITT_FALSE_POLY: u16 = 0x1021;
pub const CRC16_CCITT_FALSE_INIT: u16 = 0xFFFF;

/// Updates running CRC-16/CCITT-FALSE with one byte.
pub inline fn updateCrc16CcittFalse(crc_in: u16, byte: u8) u16 {
    var crc = crc_in ^ (@as(u16, byte) << 8);
    inline for (0..8) |_| {
        if ((crc & 0x8000) != 0) {
            crc = (crc << 1) ^ CRC16_CCITT_FALSE_POLY;
        } else {
            crc = crc << 1;
        }
    }
    return crc;
}

/// Calculates CRC-16/CCITT-FALSE over a complete byte slice.
pub fn crc16CcittFalse(data: []const u8) u16 {
    var crc: u16 = CRC16_CCITT_FALSE_INIT;
    for (data) |b| {
        crc = updateCrc16CcittFalse(crc, b);
    }
    return crc;
}

// ============================================================================
// CRC-16 / XMODEM (Polynomial 0x1021, Init 0x0000)
// ============================================================================

pub const CRC16_XMODEM_POLY: u16 = 0x1021;
pub const CRC16_XMODEM_INIT: u16 = 0x0000;

/// Updates running CRC-16/XMODEM with one byte.
pub inline fn updateCrc16Xmodem(crc_in: u16, byte: u8) u16 {
    var crc = crc_in ^ (@as(u16, byte) << 8);
    inline for (0..8) |_| {
        if ((crc & 0x8000) != 0) {
            crc = (crc << 1) ^ CRC16_XMODEM_POLY;
        } else {
            crc = crc << 1;
        }
    }
    return crc;
}

/// Calculates CRC-16/XMODEM over a complete byte slice.
pub fn crc16Xmodem(data: []const u8) u16 {
    var crc: u16 = CRC16_XMODEM_INIT;
    for (data) |b| {
        crc = updateCrc16Xmodem(crc, b);
    }
    return crc;
}

// ============================================================================
// CRC-8 (Polynomial 0x07, Init 0x00)
// ============================================================================

pub const CRC8_POLY: u8 = 0x07;
pub const CRC8_INIT: u8 = 0x00;

/// Updates running CRC-8 with one byte.
pub inline fn updateCrc8(crc_in: u8, byte: u8) u8 {
    var crc = crc_in ^ byte;
    inline for (0..8) |_| {
        if ((crc & 0x80) != 0) {
            crc = (crc << 1) ^ CRC8_POLY;
        } else {
            crc = crc << 1;
        }
    }
    return crc;
}

/// Calculates CRC-8 over a complete byte slice.
pub fn crc8(data: []const u8) u8 {
    var crc: u8 = CRC8_INIT;
    for (data) |b| {
        crc = updateCrc8(crc, b);
    }
    return crc;
}

// ============================================================================
// CRC-32 (IEEE 802.3, Polynomial 0xEDB88320)
// ============================================================================

pub const CRC32_POLY: u32 = 0xEDB88320;
pub const CRC32_INIT: u32 = 0xFFFFFFFF;

pub inline fn updateCrc32(crc_in: u32, byte: u8) u32 {
    var crc = crc_in ^ @as(u32, byte);
    inline for (0..8) |_| {
        if ((crc & 1) != 0) {
            crc = (crc >> 1) ^ CRC32_POLY;
        } else {
            crc = crc >> 1;
        }
    }
    return crc;
}

/// Calculates standard CRC-32 (IEEE 802.3) over a complete byte slice.
pub fn crc32(data: []const u8) u32 {
    var crc = CRC32_INIT;
    for (data) |b| {
        crc = updateCrc32(crc, b);
    }
    return crc ^ 0xFFFFFFFF;
}

// ============================================================================
// Tests
// ============================================================================

test "crc16 ccitt-false standard vector" {
    // "123456789" -> 0x29B1
    const test_str = "123456789";
    const res = crc16CcittFalse(test_str);
    try std.testing.expectEqual(@as(u16, 0x29B1), res);
}

test "crc16 xmodem standard vector" {
    // "123456789" -> 0x31C3
    const test_str = "123456789";
    const res = crc16Xmodem(test_str);
    try std.testing.expectEqual(@as(u16, 0x31C3), res);
}

test "crc8 standard vector" {
    // "123456789" -> 0xF4
    const test_str = "123456789";
    const res = crc8(test_str);
    try std.testing.expectEqual(@as(u8, 0xF4), res);
}

test "crc32 standard vector" {
    // "123456789" -> 0xCBF43926
    const test_str = "123456789";
    const res = crc32(test_str);
    try std.testing.expectEqual(@as(u32, 0xCBF43926), res);
}
