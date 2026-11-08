//! stdx.fs: Universal C-stdio file I/O layer.
//!
//! Provides a portable fallback when target operating systems (such as iOS Simulator / Device
//! or freestanding environments) lack complete `std.fs.cwd()` or `std.Io.Threaded` support.

const std = @import("std");

pub const c = struct {
    pub const FILE = opaque {};
    pub extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
    pub extern "c" fn fclose(stream: *FILE) c_int;
    pub extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;
    pub extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *FILE) usize;
    pub extern "c" fn fseek(stream: *FILE, offset: c_long, whence: c_int) c_int;
    pub extern "c" fn ftell(stream: *FILE) c_long;
    pub extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
    pub extern "c" fn mkdir(path: [*:0]const u8, mode: u16) c_int;
};

pub const SEEK_SET: c_int = 0;
pub const SEEK_CUR: c_int = 1;
pub const SEEK_END: c_int = 2;
pub const F_OK: c_int = 0;

pub fn fileExists(path_z: [*:0]const u8) bool {
    return c.access(path_z, F_OK) == 0;
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path_z: [*:0]const u8) ![]u8 {
    const f = c.fopen(path_z, "rb") orelse return error.FileNotFound;
    defer _ = c.fclose(f);

    if (c.fseek(f, 0, SEEK_END) != 0) return error.SeekFailed;
    const len_long = c.ftell(f);
    if (len_long < 0) return error.ReadFailed;
    const len: usize = @intCast(len_long);
    if (c.fseek(f, 0, SEEK_SET) != 0) return error.SeekFailed;

    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);

    if (len > 0) {
        const read_count = c.fread(buf.ptr, 1, len, f);
        if (read_count != len) return error.IncompleteRead;
    }
    return buf;
}

pub fn writeFile(path_z: [*:0]const u8, bytes: []const u8) !void {
    const f = c.fopen(path_z, "wb") orelse return error.AccessDenied;
    defer _ = c.fclose(f);

    if (bytes.len > 0) {
        const written = c.fwrite(bytes.ptr, 1, bytes.len, f);
        if (written != bytes.len) return error.WriteFailed;
    }
}

pub fn makeDir(path_z: [*:0]const u8) !void {
    if (c.mkdir(path_z, 0o755) != 0) {
        if (!fileExists(path_z)) return error.FailedToCreateDir;
    }
}

test "fs.stdio: write and read file" {
    const tmp_path = "/tmp/stdx_fs_test.txt";
    const expected = "Hello from stdx.fs C-stdio portable I/O!";

    try writeFile(tmp_path, expected);
    try std.testing.expect(fileExists(tmp_path));

    const content = try readFileAlloc(std.testing.allocator, tmp_path);
    defer std.testing.allocator.free(content);

    try std.testing.expectEqualStrings(expected, content);
}
