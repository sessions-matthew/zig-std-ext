//! stdx.diff: Unified diff parsing, hunk tracking, and side-by-side split row pairing.

const unified = @import("unified.zig");

pub const MaxDiffLines = unified.MaxDiffLines;
pub const MaxDiffHunks = unified.MaxDiffHunks;
pub const DiffLineKind = unified.DiffLineKind;
pub const DiffLine = unified.DiffLine;
pub const DiffSplitRow = unified.DiffSplitRow;
pub const DiffStats = unified.DiffStats;
pub const ParsedDiff = unified.ParsedDiff;
pub const parseUnifiedDiff = unified.parseUnifiedDiff;

test {
    @import("std").testing.refAllDecls(@This());
    _ = unified;
}
