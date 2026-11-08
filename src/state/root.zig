//! stdx.state: Type-hashed persistent state store, useState hooks, and inline strings.

pub const state_store = @import("state_store.zig");
pub const StateStore = state_store.StateStore;
pub const InlineString = state_store.InlineString;
pub const computeTypeHash = state_store.computeTypeHash;

test {
    _ = state_store;
}
