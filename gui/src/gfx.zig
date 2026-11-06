//! GDI+ shapes plus GDI text on a DIB back buffer. All coordinates are logical
//! pixels; the scale factor turns them into device pixels.
const std = @import("std");
const w = @import("win32.zig");
const theme = @import("theme.zig");
const Color = theme.Color;

const status_ok = 0;

pub const TextItem = struct {
    utf16: []const u16,
    font: w.HFONT,
    color: Color,
    x: f32,
    y: f32,
    tracking: i32,
};

pub const Paint = struct {
    hdc: w.HDC,
    g: *w.GpGraphics,
    memdc: w.HDC,
    bitmap: w.HBITMAP,
    bits: [*]u8,
    width: u32,
    height: u32,
    scale: f32,
    arena: std.heap.ArenaAllocator,
    texts: std.ArrayList(TextItem),
    fonts: std.ArrayList(FontEntry),
    clipped: bool = false,

    pub const FontEntry = struct { fam: u32, px: i32, bold: bool, handle: w.HFONT };

    pub fn create(gpa: std.mem.Allocator, width: u32, height: u32, scale: f32) !Paint {
        const screen = w.GetDC(null);
        defer _ = w.ReleaseDC(null, screen);
        const memdc = w.CreateCompatibleDC(screen);

        var bmi: w.BITMAPINFO = std.mem.zeroes(w.BITMAPINFO);
        bmi.bmiHeader.biSize = @sizeOf(w.BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = @intCast(width);
        bmi.bmiHeader.biHeight = -@as(w.LONG, @intCast(height));
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = w.BI_RGB;
        bmi.bmiHeader.biSizeImage = width * height * 4;

        var bits: ?*anyopaque = null;
        const bmp = w.CreateDIBSection(screen, &bmi, w.DIB_RGB_COLORS, &bits, null, 0);
        _ = w.SelectObject(memdc, bmp);

        var g: ?*w.GpGraphics = null;
        if (w.GdipCreateFromHDC(memdc, &g) != status_ok) return error.Gdiplus;
        _ = w.GdipSetSmoothingMode(g, 4); // anti-alias
        _ = w.GdipSetPixelOffsetMode(g, 4);
        _ = w.GdipSetCompositingQuality(g, 2); // high quality
        _ = w.GdipSetTextRenderingHint(g, 3);

        return .{
            .hdc = memdc,
            .g = g.?,
            .memdc = memdc,
            .bitmap = bmp,
            .bits = @ptrCast(bits.?),
            .width = width,
            .height = height,
            .scale = scale,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .texts = .empty,
            .fonts = .empty,
        };
    }

    pub fn destroy(p: *Paint) void {
        for (p.fonts.items) |f| _ = w.DeleteObject(f.handle);
        p.fonts.deinit(std.heap.page_allocator);
        p.texts.deinit(std.heap.page_allocator);
        p.arena.deinit();
        _ = w.GdipDeleteGraphics(p.g);
        _ = w.DeleteObject(p.bitmap);
        _ = w.DeleteDC(p.memdc);
    }

    pub fn beginFrame(p: *Paint) void {
        _ = p.arena.reset(.retain_capacity);
        p.texts.clearRetainingCapacity();
    }

    inline fn s(p: *const Paint, v: f32) f32 {
        return v * p.scale;
    }

    // ---- shapes -------------------------------------------------------------

    pub fn clear(p: *Paint, c: Color) void {
        var b: ?*w.GpSolidFill = null;
        if (w.GdipCreateSolidFill(c, &b) != status_ok) return;
        defer _ = w.GdipDeleteBrush(b);
        _ = w.GdipFillRectangle(p.g, b, 0, 0, @floatFromInt(p.width), @floatFromInt(p.height));
    }

    pub fn rect(p: *Paint, x: f32, y: f32, ww: f32, hh: f32, c: Color) void {
        var b: ?*w.GpSolidFill = null;
        if (w.GdipCreateSolidFill(c, &b) != status_ok) return;
        defer _ = w.GdipDeleteBrush(b);
        _ = w.GdipFillRectangle(p.g, b, p.s(x), p.s(y), p.s(ww), p.s(hh));
    }

    pub fn vgrad(p: *Paint, x: f32, y: f32, ww: f32, hh: f32, top: Color, bot: Color) void {
        var pt1: w.GpPointF = .{ .X = p.s(x), .Y = p.s(y) };
        var pt2: w.GpPointF = .{ .X = p.s(x), .Y = p.s(y + hh) };
        var b: ?*w.GpLineGradient = null;
        if (w.GdipCreateLineBrush(&pt1, &pt2, top, bot, 0, &b) != status_ok) return;
        defer _ = w.GdipDeleteBrush(b);
        _ = w.GdipFillRectangle(p.g, b, p.s(x), p.s(y), p.s(ww), p.s(hh));
    }

    pub fn roundRectPath(p: *Paint, x: f32, y: f32, ww: f32, hh: f32, r: f32) ?*w.GpPath {
        var path: ?*w.GpPath = null;
        if (w.GdipCreatePath(0, &path) != status_ok) return null;
        const X = p.s(x);
        const Y = p.s(y);
        const W = p.s(ww);
        const H = p.s(hh);
        const R = p.s(r);
        _ = w.GdipAddPathArc(path, X, Y, R * 2, R * 2, 180, 90);
        _ = w.GdipAddPathArc(path, X + W - R * 2, Y, R * 2, R * 2, 270, 90);
        _ = w.GdipAddPathArc(path, X + W - R * 2, Y + H - R * 2, R * 2, R * 2, 0, 90);
        _ = w.GdipAddPathArc(path, X, Y + H - R * 2, R * 2, R * 2, 90, 90);
        _ = w.GdipClosePathFigure(path);
        return path;
    }

    pub fn panel(p: *Paint, x: f32, y: f32, ww: f32, hh: f32, r: f32, top: Color, bot: Color, border: Color, halo: ?Color) void {
        if (halo) |gc| {
            // soft outer halo
            const path = p.roundRectPath(x - 2, y - 2, ww + 4, hh + 4, r + 2) orelse return;
            defer _ = w.GdipDeletePath(path);
            var b: ?*w.GpSolidFill = null;
            _ = w.GdipCreateSolidFill(theme.alpha(gc, 26), &b);
            _ = w.GdipFillPath(p.g, b, path);
            _ = w.GdipDeleteBrush(b);
        }
        const path = p.roundRectPath(x, y, ww, hh, r) orelse return;
        defer _ = w.GdipDeletePath(path);
        var pt1: w.GpPointF = .{ .X = p.s(x), .Y = p.s(y) };
        var pt2: w.GpPointF = .{ .X = p.s(x), .Y = p.s(y + hh) };
        var b: ?*w.GpLineGradient = null;
        if (w.GdipCreateLineBrush(&pt1, &pt2, top, bot, 0, &b) == status_ok) {
            _ = w.GdipFillPath(p.g, b, path);
            _ = w.GdipDeleteBrush(b);
        }
        p.strokePath(path, border, 1);
    }

    pub fn strokeRect(p: *Paint, x: f32, y: f32, ww: f32, hh: f32, c: Color, width: f32) void {
        const path = p.roundRectPath(x, y, ww, hh, 0) orelse return;
        defer _ = w.GdipDeletePath(path);
        p.strokePath(path, c, width);
    }

    pub fn strokePath(p: *Paint, path: *w.GpPath, c: Color, width: f32) void {
        var pen: ?*w.GpPen = null;
        if (w.GdipCreatePen1(c, p.s(width), 2, &pen) != status_ok) return;
        defer _ = w.GdipDeletePen(pen);
        _ = w.GdipDrawPath(p.g, pen, path);
    }

    pub fn line(p: *Paint, x1: f32, y1: f32, x2: f32, y2: f32, c: Color, width: f32) void {
        var pen: ?*w.GpPen = null;
        if (w.GdipCreatePen1(c, p.s(width), 2, &pen) != status_ok) return;
        defer _ = w.GdipDeletePen(pen);
        _ = w.GdipSetPenLineCap197819(pen, 2, 2, 2);
        _ = w.GdipDrawLine(p.g, pen, p.s(x1), p.s(y1), p.s(x2), p.s(y2));
    }

    pub fn dashedLine(p: *Paint, x1: f32, y1: f32, x2: f32, y2: f32, c: Color, width: f32) void {
        var pen: ?*w.GpPen = null;
        if (w.GdipCreatePen1(c, p.s(width), 2, &pen) != status_ok) return;
        defer _ = w.GdipDeletePen(pen);
        _ = w.GdipSetPenDashStyle(pen, 1);
        _ = w.GdipDrawLine(p.g, pen, p.s(x1), p.s(y1), p.s(x2), p.s(y2));
    }

    /// Radial halo: brightest at (cx, cy) and fading to transparent at radius r.
    pub fn glow(p: *Paint, cx: f32, cy: f32, rx: f32, ry: f32, c: Color, center_alpha: u8) void {
        var path: ?*w.GpPath = null;
        if (w.GdipCreatePath(0, &path) != status_ok) return;
        defer _ = w.GdipDeletePath(path);
        _ = w.GdipAddPathEllipse(path, p.s(cx - rx), p.s(cy - ry), p.s(rx * 2), p.s(ry * 2));
        var b: ?*w.GpPathGradient = null;
        if (w.GdipCreatePathGradientFromPath(path, &b) != status_ok) return;
        defer _ = w.GdipDeleteBrush(b);
        var center: w.GpPointF = .{ .X = p.s(cx), .Y = p.s(cy) };
        _ = w.GdipSetPathGradientCenterPoint(b, &center);
        var surround = [_]w.ARGB{theme.alpha(c, 0)};
        var count: w.INT = 1;
        _ = w.GdipSetPathGradientSurroundColorsWithCount(b, &surround, &count);
        _ = w.GdipSetPathGradientCenterColor(b, theme.alpha(c, center_alpha));
        _ = w.GdipFillPath(p.g, b, path);
    }

    /// Arc stroke from `start` degrees, sweeping `sweep` degrees clockwise.
    pub fn arc(p: *Paint, cx: f32, cy: f32, r: f32, width: f32, start: f32, sweep: f32, c: Color) void {
        var path: ?*w.GpPath = null;
        if (w.GdipCreatePath(0, &path) != status_ok) return;
        defer _ = w.GdipDeletePath(path);
        _ = w.GdipAddPathArc(path, p.s(cx - r), p.s(cy - r), p.s(r * 2), p.s(r * 2), start, sweep);
        var pen: ?*w.GpPen = null;
        if (w.GdipCreatePen1(c, p.s(width), 2, &pen) != status_ok) return;
        defer _ = w.GdipDeletePen(pen);
        _ = w.GdipSetPenLineCap197819(pen, 2, 2, 2);
        _ = w.GdipDrawPath(p.g, pen, path);
    }

    /// Multi-stop arc: segments interpolate between `c1` and `c2`.
    pub fn arcGradient(p: *Paint, cx: f32, cy: f32, r: f32, width: f32, start: f32, sweep: f32, c1: Color, c2: Color) void {
        if (sweep <= 0.01) return;
        const segs: u32 = @intFromFloat(@max(2, @min(64, @abs(sweep) / 3)));
        const step = sweep / @as(f32, @floatFromInt(segs));
        var i: u32 = 0;
        while (i < segs) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs));
            const col = lerpColor(c1, c2, t);
            p.arc(cx, cy, r, width, start + step * @as(f32, @floatFromInt(i)), step * 1.05, col);
        }
    }

    pub fn fillCircle(p: *Paint, cx: f32, cy: f32, r: f32, c: Color) void {
        var b: ?*w.GpSolidFill = null;
        if (w.GdipCreateSolidFill(c, &b) != status_ok) return;
        defer _ = w.GdipDeleteBrush(b);
        _ = w.GdipFillEllipse(p.g, b, p.s(cx - r), p.s(cy - r), p.s(r * 2), p.s(r * 2));
    }

    /// Area chart from a polyline of (x, y) logical points, filled with a fading gradient.
    pub fn area(p: *Paint, pts: []const w.GpPointF, base_y: f32, top: Color, bottom: Color, stroke: Color, with_glow: bool) void {
        if (pts.len < 2) return;
        var path: ?*w.GpPath = null;
        if (w.GdipCreatePath(0, &path) != status_ok) return;
        defer _ = w.GdipDeletePath(path);
        var scaled = p.arena.allocator().alloc(w.GpPointF, pts.len + 2) catch return;
        for (pts, 0..) |pt, i| scaled[i] = .{ .X = p.s(pt.X), .Y = p.s(pt.Y) };
        scaled[pts.len] = .{ .X = p.s(pts[pts.len - 1].X), .Y = p.s(base_y) };
        scaled[pts.len + 1] = .{ .X = p.s(pts[0].X), .Y = p.s(base_y) };
        _ = w.GdipAddPathLine2(path, scaled.ptr, @intCast(scaled.len));
        _ = w.GdipClosePathFigure(path);

        var min_y: f32 = 1e9;
        var max_y: f32 = -1e9;
        for (pts) |pt| {
            min_y = @min(min_y, pt.Y);
            max_y = @max(max_y, pt.Y);
        }
        var pt1: w.GpPointF = .{ .X = 0, .Y = p.s(@min(min_y, base_y)) };
        var pt2: w.GpPointF = .{ .X = 0, .Y = p.s(base_y) };
        var b: ?*w.GpLineGradient = null;
        if (w.GdipCreateLineBrush(&pt1, &pt2, top, bottom, 0, &b) == status_ok) {
            _ = w.GdipFillPath(p.g, b, path);
            _ = w.GdipDeleteBrush(b);
        }

        // stroke the line itself
        var lpath: ?*w.GpPath = null;
        if (w.GdipCreatePath(0, &lpath) != status_ok) return;
        defer _ = w.GdipDeletePath(lpath);
        var lp = p.arena.allocator().alloc(w.GpPointF, pts.len) catch return;
        for (pts, 0..) |pt, i| lp[i] = .{ .X = p.s(pt.X), .Y = p.s(pt.Y) };
        _ = w.GdipAddPathLine2(lpath, lp.ptr, @intCast(lp.len));
        if (with_glow) {
            var gp: ?*w.GpPen = null;
            if (w.GdipCreatePen1(theme.alpha(stroke, 45), p.s(7), 2, &gp) == status_ok) {
                _ = w.GdipSetPenLineCap197819(gp, 2, 2, 2);
                _ = w.GdipSetPenLineJoin(gp, 2);
                _ = w.GdipDrawPath(p.g, gp, lpath);
                _ = w.GdipDeletePen(gp);
            }
        }
        var pen: ?*w.GpPen = null;
        if (w.GdipCreatePen1(stroke, p.s(2), 2, &pen) != status_ok) return;
        defer _ = w.GdipDeletePen(pen);
        _ = w.GdipSetPenLineCap197819(pen, 2, 2, 2);
        _ = w.GdipSetPenLineJoin(pen, 2);
        _ = w.GdipDrawPath(p.g, pen, lpath);
    }

    pub fn clip(p: *Paint, x: f32, y: f32, ww: f32, hh: f32) void {
        _ = w.GdipSetClipRect(p.g, p.s(x), p.s(y), p.s(ww), p.s(hh), 0);
        p.clipped = true;
    }

    pub fn resetClip(p: *Paint) void {
        _ = w.GdipResetClip(p.g);
        p.clipped = false;
    }

    // ---- text ---------------------------------------------------------------

    fn fontHandle(p: *Paint, fam: u32, px: f32, bold: bool) w.HFONT {
        const ipx: i32 = @intFromFloat(@round(px * p.scale));
        for (p.fonts.items) |f| if (f.fam == fam and f.px == ipx and f.bold == bold) return f.handle;
        const face: []const u8 = switch (fam) {
            0 => theme.ui_family,
            1 => theme.mono_family,
            else => theme.mono_fallback,
        };
        const u16s = std.unicode.utf8ToUtf16LeAllocZ(p.arena.allocator(), face) catch return null;
        const handle = w.CreateFontW(-ipx, 0, 0, 0, if (bold) 700 else 400, 0, 0, 0, w.DEFAULT_CHARSET, w.OUT_TT_PRECIS, w.CLIP_DEFAULT_PRECIS, w.ANTIALIASED_QUALITY, w.DEFAULT_PITCH, u16s.ptr);
        p.fonts.append(std.heap.page_allocator, .{ .fam = fam, .px = ipx, .bold = bold, .handle = handle }) catch {};
        return handle;
    }

    fn famId(f: theme.Font) u32 {
        return switch (f) {
            .ui, .display, .display_small, .ui_bold, .ui_small, .ui_label => 0,
            .mono, .mono_bold => 1,
        };
    }

    pub fn textWidth(p: *Paint, str: []const u8, f: theme.Font, tracking: i32) f32 {
        const spec = theme.fontSpec(f);
        const u16s = std.unicode.utf8ToUtf16LeAlloc(p.arena.allocator(), str) catch return 0;
        const font = p.fontHandle(famId(f), spec.px, spec.bold);
        const old = w.SelectObject(p.hdc, font);
        defer _ = w.SelectObject(p.hdc, old);
        _ = w.SetTextCharacterExtra(p.hdc, @intFromFloat(@round(@as(f32, @floatFromInt(tracking)) * p.scale)));
        var size: w.SIZE = undefined;
        _ = w.GetTextExtentPoint32W(p.hdc, u16s.ptr, @intCast(u16s.len), &size);
        return @as(f32, @floatFromInt(size.cx)) / p.scale;
    }

    pub fn text(p: *Paint, str: []const u8, f: theme.Font, c: Color, x: f32, y: f32) void {
        const spec = theme.fontSpec(f);
        const u16s = std.unicode.utf8ToUtf16LeAlloc(p.arena.allocator(), str) catch return;
        const font = p.fontHandle(famId(f), spec.px, spec.bold);
        p.texts.append(std.heap.page_allocator, .{ .utf16 = u16s, .font = font, .color = c, .x = x, .y = y, .tracking = spec.tracking }) catch {};
    }

    pub fn textRight(p: *Paint, str: []const u8, f: theme.Font, c: Color, right_x: f32, y: f32) void {
        p.text(str, f, c, right_x - p.textWidth(str, f, 0), y);
    }

    pub fn textCentered(p: *Paint, str: []const u8, f: theme.Font, c: Color, cx: f32, y: f32) void {
        p.text(str, f, c, cx - p.textWidth(str, f, 0) / 2, y);
    }

    /// Draws `str` inside `max_w`, cutting it with an ellipsis when it does not fit.
    pub fn textFit(p: *Paint, str: []const u8, f: theme.Font, c: Color, x: f32, y: f32, max_w: f32) void {
        const ellipsis = [_]u8{ '.', '.', '.' };
        if (p.textWidth(str, f, 0) <= max_w) {
            p.text(str, f, c, x, y);
            return;
        }
        var lo: usize = 0;
        var hi: usize = str.len;
        while (lo < hi) {
            const mid = (lo + hi + 1) / 2;
            const cand = p.arena.allocator().alloc(u8, mid + 3) catch return;
            @memcpy(cand[0..mid], str[0..mid]);
            @memcpy(cand[mid .. mid + 3], &ellipsis);
            if (p.textWidth(cand, f, 0) <= max_w) lo = mid else hi = mid - 1;
        }
        const cand = p.arena.allocator().alloc(u8, lo + 3) catch return;
        @memcpy(cand[0..lo], str[0..lo]);
        @memcpy(cand[lo .. lo + 3], &ellipsis);
        p.text(cand, f, c, x, y);
    }

    pub fn textTracking(p: *Paint, str: []const u8, f: theme.Font, c: Color, x: f32, y: f32, tracking: i32) void {
        const spec = theme.fontSpec(f);
        const u16s = std.unicode.utf8ToUtf16LeAlloc(p.arena.allocator(), str) catch return;
        const font = p.fontHandle(famId(f), spec.px, spec.bold);
        p.texts.append(std.heap.page_allocator, .{ .utf16 = u16s, .font = font, .color = c, .x = x, .y = y, .tracking = tracking }) catch {};
    }

    /// Draws every queued string with GDI after flushing GDI+ to the same DC.
    /// Draw everything queued so far and drop it, so shapes painted afterwards
    /// (an opaque modal scrim, say) really sit on top of that text.
    pub fn flushTextNow(p: *Paint) void {
        p.flushText();
        p.texts.clearRetainingCapacity();
    }
    pub fn flushText(p: *Paint) void {
        _ = w.GdipFlush(p.g, 0);
        _ = w.SetBkMode(p.hdc, w.TRANSPARENT);
        for (p.texts.items) |t| {
            _ = w.SelectObject(p.hdc, t.font);
            _ = w.SetTextCharacterExtra(p.hdc, @intFromFloat(@round(@as(f32, @floatFromInt(t.tracking)) * p.scale)));
            _ = w.SetTextColor(p.hdc, colorref(t.color));
            _ = w.TextOutW(p.hdc, @intFromFloat(@round(t.x * p.scale)), @intFromFloat(@round(t.y * p.scale)), t.utf16.ptr, @intCast(t.utf16.len));
        }
    }

    pub fn present(p: *Paint, hdc: w.HDC) void {
        p.flushText();
        _ = w.BitBlt(hdc, 0, 0, @intCast(p.width), @intCast(p.height), p.memdc, 0, 0, w.SRCCOPY);
    }

    /// Saves the back buffer as a 32-bit BMP (bottom-up, as viewers expect).
    pub fn saveBmp(p: *Paint, io: std.Io, path: []const u8) !void {
        p.flushText();
        var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
        defer file.close(io);
        var hdr: [14]u8 = undefined;
        const file_size: u32 = 14 + 40 + p.width * p.height * 4;
        hdr[0] = 'B';
        hdr[1] = 'M';
        std.mem.writeInt(u32, hdr[2..6], file_size, .little);
        std.mem.writeInt(u32, hdr[6..10], 0, .little);
        std.mem.writeInt(u32, hdr[10..14], 54, .little);
        try file.writeStreamingAll(io, &hdr);
        var info: [40]u8 = std.mem.zeroes([40]u8);
        std.mem.writeInt(u32, info[0..4], 40, .little);
        std.mem.writeInt(i32, info[4..8], @intCast(p.width), .little);
        std.mem.writeInt(i32, info[8..12], @intCast(p.height), .little);
        std.mem.writeInt(u16, info[12..14], 1, .little);
        std.mem.writeInt(u16, info[14..16], 32, .little);
        std.mem.writeInt(u32, info[20..24], p.width * p.height * 4, .little);
        try file.writeStreamingAll(io, &info);
        const stride = p.width * 4;
        var row: u32 = 0;
        while (row < p.height) : (row += 1) {
            const src = p.height - 1 - row;
            try file.writeStreamingAll(io, p.bits[src * stride .. src * stride + stride]);
        }
    }
};

pub fn colorref(c: Color) w.COLORREF {
    return (@as(u32, (c >> 16) & 0xFF)) | (@as(u32, (c >> 8) & 0xFF) << 8) | (@as(u32, c & 0xFF) << 16);
}

pub fn lerpColor(a: Color, b: Color, t: f32) Color {
    const ar: f32 = @floatFromInt((a >> 16) & 0xFF);
    const ag: f32 = @floatFromInt((a >> 8) & 0xFF);
    const ab: f32 = @floatFromInt(a & 0xFF);
    const br: f32 = @floatFromInt((b >> 16) & 0xFF);
    const bg: f32 = @floatFromInt((b >> 8) & 0xFF);
    const bb: f32 = @floatFromInt(b & 0xFF);
    return theme.rgb(
        @intFromFloat(ar + (br - ar) * t),
        @intFromFloat(ag + (bg - ag) * t),
        @intFromFloat(ab + (bb - ab) * t),
    );
}
