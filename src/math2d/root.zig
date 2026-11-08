//! stdx.math2d: 2D Vectors, Rects, Transforms, Camera Projections, and Easing.

const std = @import("std");

pub const FitMode = enum {
    contain,
    cover,
    fill_width,
    stretch,
};

pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn init(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    pub fn scale(v: Vec2, s: f32) Vec2 {
        return .{ .x = v.x * s, .y = v.y * s };
    }

    pub fn lengthSq(v: Vec2) f32 {
        return v.x * v.x + v.y * v.y;
    }

    pub fn length(v: Vec2) f32 {
        return @sqrt(v.lengthSq());
    }

    pub fn normalize(v: Vec2) Vec2 {
        const len = v.length();
        if (len == 0) return v;
        return v.scale(1.0 / len);
    }
};

pub const Rect = struct {
    left: f32 = 0,
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,

    pub fn xywh(x: f32, y: f32, w: f32, h: f32) Rect {
        return .{
            .left = x,
            .top = y,
            .right = x + w,
            .bottom = y + h,
        };
    }

    pub fn width(r: Rect) f32 {
        return r.right - r.left;
    }

    pub fn height(r: Rect) f32 {
        return r.bottom - r.top;
    }

    pub fn contains(r: Rect, p: Vec2) bool {
        return p.x >= r.left and p.x <= r.right and p.y >= r.top and p.y <= r.bottom;
    }

    pub fn intersects(a: Rect, b: Rect) bool {
        return a.left < b.right and a.right > b.left and a.top < b.bottom and a.bottom > b.top;
    }
};

/// Projects between authored 2D stage coordinates (e.g. 1920x1080) and viewport pixels.
pub const StageCamera = struct {
    win_rect: Rect,
    stage_w: f32,
    stage_h: f32,
    scale_x: f32,
    scale_y: f32,
    uniform_scale: f32,
    offset_x: f32,
    offset_y: f32,

    pub fn init(win_rect: Rect, stage_w: f32, stage_h: f32, fit_mode: FitMode) StageCamera {
        const win_w = @max(1.0, win_rect.width());
        const win_h = @max(1.0, win_rect.height());
        const sw = @max(1.0, stage_w);
        const sh = @max(1.0, stage_h);

        const sx_raw = win_w / sw;
        const sy_raw = win_h / sh;
        const contain_s = @min(sx_raw, sy_raw);
        const cover_s = @max(sx_raw, sy_raw);

        var sx: f32 = contain_s;
        var sy: f32 = contain_s;
        var uni: f32 = contain_s;

        switch (fit_mode) {
            .contain => {
                sx = contain_s;
                sy = contain_s;
                uni = contain_s;
            },
            .cover => {
                sx = cover_s;
                sy = cover_s;
                uni = cover_s;
            },
            .fill_width => {
                sx = sx_raw;
                sy = contain_s;
                uni = sx_raw;
            },
            .stretch => {
                sx = sx_raw;
                sy = sy_raw;
                uni = contain_s;
            },
        }

        const drawn_w = sw * sx;
        const drawn_h = sh * sy;

        return .{
            .win_rect = win_rect,
            .stage_w = sw,
            .stage_h = sh,
            .scale_x = sx,
            .scale_y = sy,
            .uniform_scale = uni,
            .offset_x = win_rect.left + (win_w - drawn_w) * 0.5,
            .offset_y = win_rect.top + (win_h - drawn_h) * 0.5,
        };
    }

    pub fn stageRect(self: StageCamera, x: f32, y: f32, w: f32, h: f32) Rect {
        return Rect.xywh(
            self.offset_x + x * self.scale_x,
            self.offset_y + y * self.scale_y,
            w * self.scale_x,
            h * self.scale_y,
        );
    }

    pub fn stagePoint(self: StageCamera, x: f32, y: f32) Vec2 {
        return .{
            .x = self.offset_x + x * self.scale_x,
            .y = self.offset_y + y * self.scale_y,
        };
    }
};

/// Expands `rect` to at least `min_size` x `min_size` (default 44x44 pt Apple HIG touch target).
pub fn expandHitRect(rect: Rect, min_size: f32) Rect {
    var r = rect;
    const w = r.width();
    const h = r.height();
    if (w < min_size) {
        const pad = (min_size - w) * 0.5;
        r.left -= pad;
        r.right += pad;
    }
    if (h < min_size) {
        const pad = (min_size - h) * 0.5;
        r.top -= pad;
        r.bottom += pad;
    }
    return r;
}

pub const Easing = struct {
    pub fn easeOutCubic(t: f32) f32 {
        const u = 1.0 - std.math.clamp(t, 0.0, 1.0);
        return 1.0 - u * u * u;
    }

    pub fn easeOutBack(t: f32) f32 {
        const c1: f32 = 1.70158;
        const c3: f32 = c1 + 1.0;
        const u = std.math.clamp(t, 0.0, 1.0) - 1.0;
        return 1.0 + c3 * u * u * u + c1 * u * u;
    }
};

test "math2d: Vec2, Rect, and StageCamera" {
    const v1 = Vec2.init(3, 4);
    try std.testing.expectEqual(@as(f32, 5.0), v1.length());

    const r = Rect.xywh(10, 20, 100, 200);
    try std.testing.expect(r.contains(Vec2.init(50, 50)));
    try std.testing.expect(!r.contains(Vec2.init(5, 5)));

    const small = Rect.xywh(10, 10, 20, 20);
    const expanded = expandHitRect(small, 44.0);
    try std.testing.expectEqual(@as(f32, 44.0), expanded.width());
    try std.testing.expectEqual(@as(f32, 44.0), expanded.height());
}
