//! stdx.diff: Zero-allocation Unified Diff and Patch Parser.
//!
//! Parses standard git / unified diff text (`diff --git`, `@@ -a,b +c,d @@`, `+`, `-`),
//! tracks old and new line numbers, and pairs modification hunks for side-by-side split views.

const std = @import("std");

pub const MaxDiffLines: usize = 2048;
pub const MaxDiffHunks: usize = 128;

pub const DiffLineKind = enum(u8) {
    file_header = 0,
    hunk_header = 1,
    context = 2,
    addition = 3,
    deletion = 4,
};

pub const DiffLine = struct {
    kind: DiffLineKind = .context,
    old_line: u32 = 0,
    new_line: u32 = 0,
    text: []const u8 = "",
};

pub const DiffSplitRow = struct {
    is_header: bool = false,
    header_kind: DiffLineKind = .hunk_header,
    header_text: []const u8 = "",
    left_present: bool = false,
    left_kind: DiffLineKind = .context,
    left_line: u32 = 0,
    left_text: []const u8 = "",
    right_present: bool = false,
    right_kind: DiffLineKind = .context,
    right_line: u32 = 0,
    right_text: []const u8 = "",
};

pub const DiffStats = struct {
    additions: u32 = 0,
    deletions: u32 = 0,
    hunks: u32 = 0,
};

pub const ParsedDiff = struct {
    lines: [MaxDiffLines]DiffLine = undefined,
    line_count: usize = 0,
    split_rows: [MaxDiffLines]DiffSplitRow = undefined,
    split_row_count: usize = 0,
    hunk_unified_rows: [MaxDiffHunks]u32 = @splat(0),
    hunk_split_rows: [MaxDiffHunks]u32 = @splat(0),
    stats: DiffStats = .{},
};

fn parseHunkStartNumbers(line: []const u8) struct { old_start: u32, new_start: u32 } {
    var old_start: u32 = 1;
    var new_start: u32 = 1;

    if (std.mem.indexOf(u8, line, "-")) |dash_idx| {
        const after_dash = line[dash_idx + 1 ..];
        var d_end: usize = 0;
        while (d_end < after_dash.len and std.ascii.isDigit(after_dash[d_end])) : (d_end += 1) {}
        if (d_end > 0) {
            old_start = std.fmt.parseInt(u32, after_dash[0..d_end], 10) catch 1;
        }
    }
    if (std.mem.indexOf(u8, line, "+")) |plus_idx| {
        const after_plus = line[plus_idx + 1 ..];
        var d_end: usize = 0;
        while (d_end < after_plus.len and std.ascii.isDigit(after_plus[d_end])) : (d_end += 1) {}
        if (d_end > 0) {
            new_start = std.fmt.parseInt(u32, after_plus[0..d_end], 10) catch 1;
        }
    }
    return .{ .old_start = old_start, .new_start = new_start };
}

/// Zero-allocation parser that populates `out.lines` (for Unified mode) and `out.split_rows`
/// (for Side-by-Side Split mode) directly from `diff_text`.
pub fn parseUnifiedDiff(diff_text: []const u8, out: *ParsedDiff) void {
    out.line_count = 0;
    out.split_row_count = 0;
    out.stats = .{};

    var cur_old_line: u32 = 1;
    var cur_new_line: u32 = 1;
    var in_hunk = false;

    var line_it = std.mem.splitScalar(u8, diff_text, '\n');
    while (line_it.next()) |raw_line| {
        if (out.line_count >= MaxDiffLines) break;
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0 and !in_hunk) continue;

        if (std.mem.startsWith(u8, line, "diff --git ")) {
            in_hunk = false;
            var header_label = line["diff --git ".len..];
            if (std.mem.indexOf(u8, header_label, " b/")) |b_idx| {
                header_label = header_label[b_idx + 3 ..];
            }
            out.lines[out.line_count] = .{
                .kind = .file_header,
                .old_line = 0,
                .new_line = 0,
                .text = header_label,
            };
            out.line_count += 1;
            continue;
        }

        if (std.mem.startsWith(u8, line, "index ") or
            std.mem.startsWith(u8, line, "--- ") or
            std.mem.startsWith(u8, line, "+++ ") or
            std.mem.startsWith(u8, line, "new file mode ") or
            std.mem.startsWith(u8, line, "deleted file mode "))
        {
            continue;
        }

        if (std.mem.startsWith(u8, line, "@@")) {
            in_hunk = true;
            const starts = parseHunkStartNumbers(line);
            cur_old_line = starts.old_start;
            cur_new_line = starts.new_start;
            if (out.stats.hunks < MaxDiffHunks) {
                out.hunk_unified_rows[out.stats.hunks] = @intCast(out.line_count);
            }
            out.stats.hunks += 1;
            out.lines[out.line_count] = .{
                .kind = .hunk_header,
                .old_line = cur_old_line,
                .new_line = cur_new_line,
                .text = line,
            };
            out.line_count += 1;
            continue;
        }

        if (!in_hunk) {
            if (std.mem.startsWith(u8, line, "commit ") or
                std.mem.startsWith(u8, line, "Author:") or
                std.mem.startsWith(u8, line, "Date:"))
            {
                out.lines[out.line_count] = .{
                    .kind = .file_header,
                    .old_line = 0,
                    .new_line = 0,
                    .text = line,
                };
                out.line_count += 1;
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "\\ No newline")) continue;

        if (line.len > 0 and line[0] == '+') {
            out.lines[out.line_count] = .{
                .kind = .addition,
                .old_line = 0,
                .new_line = cur_new_line,
                .text = line[1..],
            };
            cur_new_line += 1;
            out.stats.additions += 1;
            out.line_count += 1;
        } else if (line.len > 0 and line[0] == '-') {
            out.lines[out.line_count] = .{
                .kind = .deletion,
                .old_line = cur_old_line,
                .new_line = 0,
                .text = line[1..],
            };
            cur_old_line += 1;
            out.stats.deletions += 1;
            out.line_count += 1;
        } else {
            const body = if (line.len > 0 and line[0] == ' ') line[1..] else line;
            out.lines[out.line_count] = .{
                .kind = .context,
                .old_line = cur_old_line,
                .new_line = cur_new_line,
                .text = body,
            };
            cur_old_line += 1;
            cur_new_line += 1;
            out.line_count += 1;
        }
    }

    // Populate split view side-by-side rows
    buildSplitRows(out);
}

fn buildSplitRows(out: *ParsedDiff) void {
    var i: usize = 0;
    while (i < out.line_count and out.split_row_count < MaxDiffLines) {
        const line = out.lines[i];
        if (line.kind == .file_header or line.kind == .hunk_header) {
            if (line.kind == .hunk_header and out.stats.hunks > 0) {
                // Map hunk to split row index
                for (0..out.stats.hunks) |h| {
                    if (out.hunk_unified_rows[h] == @as(u32, @intCast(i))) {
                        out.hunk_split_rows[h] = @intCast(out.split_row_count);
                        break;
                    }
                }
            }
            out.split_rows[out.split_row_count] = .{
                .is_header = true,
                .header_kind = line.kind,
                .header_text = line.text,
            };
            out.split_row_count += 1;
            i += 1;
            continue;
        }

        if (line.kind == .context) {
            out.split_rows[out.split_row_count] = .{
                .left_present = true,
                .left_kind = .context,
                .left_line = line.old_line,
                .left_text = line.text,
                .right_present = true,
                .right_kind = .context,
                .right_line = line.new_line,
                .right_text = line.text,
            };
            out.split_row_count += 1;
            i += 1;
            continue;
        }

        // Gather contiguous deletions and additions
        const del_start = i;
        while (i < out.line_count and out.lines[i].kind == .deletion) : (i += 1) {}
        const del_count = i - del_start;

        const add_start = i;
        while (i < out.line_count and out.lines[i].kind == .addition) : (i += 1) {}
        const add_count = i - add_start;

        const pair_count = @max(del_count, add_count);
        for (0..pair_count) |p| {
            if (out.split_row_count >= MaxDiffLines) break;
            var row = DiffSplitRow{};
            if (p < del_count) {
                const dl = out.lines[del_start + p];
                row.left_present = true;
                row.left_kind = .deletion;
                row.left_line = dl.old_line;
                row.left_text = dl.text;
            }
            if (p < add_count) {
                const al = out.lines[add_start + p];
                row.right_present = true;
                row.right_kind = .addition;
                row.right_line = al.new_line;
                row.right_text = al.text;
            }
            out.split_rows[out.split_row_count] = row;
            out.split_row_count += 1;
        }
    }
}

test "diff: parseUnifiedDiff counts additions, deletions, and hunks" {
    const sample =
        \\diff --git a/src/main.zig b/src/main.zig
        \\index 1234..5678 100644
        \\--- a/src/main.zig
        \\+++ b/src/main.zig
        \\@@ -10,4 +10,5 @@ fn start() void {
        \\ context_line_1
        \\-old_bad_line
        \\+new_good_line
        \\+another_new_line
        \\ context_line_2
    ;

    var parsed: ParsedDiff = undefined;
    parseUnifiedDiff(sample, &parsed);

    try std.testing.expectEqual(@as(u32, 1), parsed.stats.hunks);
    try std.testing.expectEqual(@as(u32, 2), parsed.stats.additions);
    try std.testing.expectEqual(@as(u32, 1), parsed.stats.deletions);

    // Verify side-by-side row pairing
    try std.testing.expect(parsed.split_row_count > 0);
}
