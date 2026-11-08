//! Host-owned Type-Hashed Key-Value Store (`useState` + scopes) and Reload-Boundary Buffer.
//!
//! Safely crosses dynamic code reload boundaries without storing pointer addresses across reloads:
//!   1. Validates compile-time structural type hashes on access.
//!   2. Automatically frees and re-initializes only modified types if a struct layout evolves.
//!   3. Provides fixed-capacity inline strings safe against string-literal invalidation.

const std = @import("std");

pub const StateEntry = struct {
    ptr: [*]u8,
    size: usize,
    alignment: u8,
    type_hash: u64,
};

/// Host-owned persistent Key-Value store for component-scoped `useState` hooks.
pub const StateStore = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged(u64, StateEntry) = .empty,
    scope_stack: [32]u64 = @splat(0),
    scope_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) StateStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StateStore) void {
        var it = self.map.valueIterator();
        while (it.next()) |entry| {
            const slice = entry.ptr[0..entry.size];
            self.allocator.rawFree(slice, @enumFromInt(entry.alignment), @returnAddress());
        }
        self.map.deinit(self.allocator);
        self.scope_len = 0;
    }

    pub fn resetScopes(self: *StateStore) void {
        self.scope_len = 0;
    }

    pub fn currentScopeId(self: *const StateStore) u64 {
        return if (self.scope_len > 0) self.scope_stack[self.scope_len - 1] else 0;
    }

    pub fn pushScope(self: *StateStore, scope_name: []const u8) void {
        const parent = self.currentScopeId();
        const next_id = std.hash.Wyhash.hash(parent, scope_name);
        std.debug.assert(self.scope_len < self.scope_stack.len);
        self.scope_stack[self.scope_len] = next_id;
        self.scope_len += 1;
    }

    pub fn popScope(self: *StateStore) void {
        if (self.scope_len > 0) {
            self.scope_len -= 1;
        }
    }

    /// Looks up or allocates a state slot of `(size, alignment, type_hash)` under `(currentScopeId, key)`.
    /// Sets `initialized_out.* = true` if the existing slot matched `type_hash` and `size`,
    /// or `false` if a fresh allocation was created (or re-allocated after a type change).
    pub fn getOrAllocRaw(
        self: *StateStore,
        key: []const u8,
        size: usize,
        alignment_log2: u8,
        type_hash: u64,
        initialized_out: *bool,
    ) [*]u8 {
        const full_key = std.hash.Wyhash.hash(self.currentScopeId(), key);

        if (self.map.getPtr(full_key)) |entry| {
            if (entry.type_hash == type_hash and entry.size == size and entry.alignment == alignment_log2) {
                initialized_out.* = true;
                return entry.ptr;
            }
            // Type signature or size changed! Free old memory and re-allocate.
            const old_slice = entry.ptr[0..entry.size];
            self.allocator.rawFree(old_slice, @enumFromInt(entry.alignment), @returnAddress());
        }

        const raw_ptr = self.allocator.rawAlloc(size, @enumFromInt(alignment_log2), @returnAddress()) orelse
            @panic("OOM in StateStore.getOrAllocRaw");

        self.map.put(self.allocator, full_key, .{
            .ptr = raw_ptr,
            .size = size,
            .alignment = alignment_log2,
            .type_hash = type_hash,
        }) catch @panic("OOM in StateStore.map.put");

        initialized_out.* = false;
        return raw_ptr;
    }

    pub fn useState(self: *StateStore, comptime T: type, key: []const u8, default_val: T) *T {
        var initialized = false;
        const raw = self.getOrAllocRaw(
            key,
            @sizeOf(T),
            @intCast(std.math.log2(@alignOf(T))),
            computeTypeHash(T),
            &initialized,
        );
        const ptr: *T = @ptrCast(@alignCast(raw));
        if (!initialized) {
            ptr.* = default_val;
        }
        return ptr;
    }

    pub fn remove(self: *StateStore, key: []const u8) bool {
        const full_key = std.hash.Wyhash.hash(self.currentScopeId(), key);
        if (self.map.fetchRemove(full_key)) |kv| {
            const slice = kv.value.ptr[0..kv.value.size];
            self.allocator.rawFree(slice, @enumFromInt(kv.value.alignment), @returnAddress());
            return true;
        }
        return false;
    }

    pub fn count(self: *const StateStore) usize {
        return self.map.count();
    }
};

/// Fixed-capacity UTF-8 string value safe to store inside persistent state.
pub fn InlineString(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        pub const Capacity = capacity;

        buf: [capacity]u8 = @splat(0),
        len: usize = 0,

        pub fn init(str: []const u8) Self {
            var s = Self{};
            s.set(str);
            return s;
        }

        pub fn set(self: *Self, str: []const u8) void {
            const n = @min(str.len, capacity);
            @memcpy(self.buf[0..n], str[0..n]);
            self.len = n;
        }

        pub fn appendSlice(self: *Self, str: []const u8) void {
            const cur = @min(self.len, capacity);
            const avail = capacity - cur;
            const n = @min(str.len, avail);
            if (n > 0) {
                @memcpy(self.buf[cur .. cur + n], str[0..n]);
                self.len = cur + n;
            }
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..@min(self.len, capacity)];
        }

        pub fn eql(self: *const Self, other: []const u8) bool {
            return std.mem.eql(u8, self.slice(), other);
        }
    };
}

/// Generates a compile-time structural hash of `T`'s layout, field names, and types.
pub fn computeTypeHash(comptime T: type) u64 {
    return comptime blk: {
        @setEvalBranchQuota(50_000);
        break :blk computeTypeHashDepth(T, 0);
    };
}

fn computeTypeHashDepth(comptime T: type, comptime depth: usize) u64 {
    comptime {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(@typeName(T));
        const sz: usize = @sizeOf(T);
        const al: usize = @alignOf(T);
        hasher.update(std.mem.asBytes(&sz));
        hasher.update(std.mem.asBytes(&al));

        if (depth < 4) {
            switch (@typeInfo(T)) {
                .@"struct" => |info| {
                    for (info.field_names, info.field_types) |fname, FType| {
                        hasher.update(fname);
                        const field_hash = computeTypeHashDepth(FType, depth + 1);
                        hasher.update(std.mem.asBytes(&field_hash));
                    }
                },
                .@"enum" => |info| {
                    for (info.field_names, info.field_values) |fname, fval| {
                        hasher.update(fname);
                        const val: i128 = @intCast(fval);
                        hasher.update(std.mem.asBytes(&val));
                    }
                },
                .@"union" => |info| {
                    for (info.field_names, info.field_types) |fname, FType| {
                        hasher.update(fname);
                        const field_hash = computeTypeHashDepth(FType, depth + 1);
                        hasher.update(std.mem.asBytes(&field_hash));
                    }
                },
                else => {},
            }
        }
        const final = hasher.final();
        return if (final == 0) 1 else final;
    }
}

test "StateStore: useState, scopes, and persistence" {
    var store = StateStore.init(std.testing.allocator);
    defer store.deinit();

    const Counter = struct { value: i32 = 0 };

    store.pushScope("sidebar");
    const c1 = store.useState(Counter, "counter", .{ .value = 10 });
    try std.testing.expectEqual(@as(i32, 10), c1.value);
    c1.value += 5;

    // Re-accessing in same scope returns modified state
    const c2 = store.useState(Counter, "counter", .{ .value = 10 });
    try std.testing.expectEqual(@as(i32, 15), c2.value);
    store.popScope();

    // Different scope has independent state
    store.pushScope("footer");
    const c3 = store.useState(Counter, "counter", .{ .value = 100 });
    try std.testing.expectEqual(@as(i32, 100), c3.value);
    store.popScope();
}
