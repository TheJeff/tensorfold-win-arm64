//! Renders the TensorFold mark (the glowing violet orb from the header) into a
//! multi-size .ico for the window, taskbar and the executable's own resources.
//! Pure software rendering on purpose: GDI+ on a 32bpp DIB writes premultiplied
//! pixels, and ICO entries want straight alpha.

const std = @import("std");

const violet = [3]f32{ 0xB5, 0x7C, 0xFF };
const core = [3]f32{ 250, 245, 255 };

fn writeU16(buf: []u8, v: u16) void {
    buf[0] = @intCast(v & 0xff);
    buf[1] = @intCast((v >> 8) & 0xff);
}

fn writeU32(buf: []u8, v: u32) void {
    buf[0] = @intCast(v & 0xff);
    buf[1] = @intCast((v >> 8) & 0xff);
    buf[2] = @intCast((v >> 16) & 0xff);
    buf[3] = @intCast((v >> 24) & 0xff);
}

fn maskBytes(s: usize) usize {
    return ((s + 31) / 32) * 4 * s;
}

fn imageBytes(s: usize) usize {
    return 40 + s * s * 4 + maskBytes(s);
}

/// Soft disc coverage: 1 inside r-0.5, falling to 0 at r+0.5.
fn cover(d: f32, r: f32) f32 {
    return std.math.clamp((r + 0.5 - d) / 1.0, 0.0, 1.0);
}

const Acc = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 0,

    fn over(self: *Acc, c: [3]f32, a: f32) void {
        const inv = 1.0 - a;
        self.r = c[0] * a + self.r * inv;
        self.g = c[1] * a + self.g * inv;
        self.b = c[2] * a + self.b * inv;
        self.a = a + self.a * inv;
    }
};

fn renderRgba(alloc: std.mem.Allocator, s: usize) ![]u8 {
    const px = try alloc.alloc(u8, s * s * 4);
    const c = @as(f32, @floatFromInt(s)) / 2.0;
    const fs: f32 = @floatFromInt(s);
    // small sizes need a fatter disc and a tighter glow or they read as a blur
    const small = s <= 32;
    const rg = (if (small) @as(f32, 0.52) else @as(f32, 0.48)) * fs;
    const rd = (if (small) @as(f32, 0.30) else @as(f32, 0.235)) * fs;
    const rc = (if (small) @as(f32, 0.145) else @as(f32, 0.105)) * fs;
    const glow_peak: f32 = if (small) @as(f32, 0.34) else @as(f32, 0.55);

    var y: usize = 0;
    while (y < s) : (y += 1) {
        var x: usize = 0;
        while (x < s) : (x += 1) {
            const fx = @as(f32, @floatFromInt(x)) + 0.5;
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            const dx = fx - c;
            const dy = fy - c;
            const d = @sqrt(dx * dx + dy * dy);

            var acc = Acc{};
            const t = d / rg;
            const glow = glow_peak * std.math.exp(-4.5 * t * t);
            if (glow > 0.002) acc.over(violet, glow);
            const disc = cover(d, rd);
            if (disc > 0) acc.over(violet, disc);
            const k = cover(d, rc);
            if (k > 0) acc.over(core, k);

            const o = (y * s + x) * 4;
            if (acc.a <= 0.002) {
                px[o] = 0;
                px[o + 1] = 0;
                px[o + 2] = 0;
                px[o + 3] = 0;
            } else {
                // straight (non-premultiplied) alpha, which is what ICO wants
                px[o] = @intFromFloat(std.math.clamp(acc.r / acc.a, 0, 255));
                px[o + 1] = @intFromFloat(std.math.clamp(acc.g / acc.a, 0, 255));
                px[o + 2] = @intFromFloat(std.math.clamp(acc.b / acc.a, 0, 255));
                px[o + 3] = @intFromFloat(std.math.clamp(acc.a * 255.0, 0, 255));
            }
        }
    }
    return px;
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const io = init.io;

    const sizes = [_]usize{ 16, 20, 24, 32, 40, 48, 64, 128, 256 };

    var total: usize = 6 + 16 * sizes.len;
    for (sizes) |s| total += imageBytes(s);

    const out = try alloc.alloc(u8, total);
    defer alloc.free(out);

    out[0] = 0;
    out[1] = 0;
    out[2] = 1;
    out[3] = 0;
    writeU16(out[4..], @intCast(sizes.len));

    var off: usize = 6 + 16 * sizes.len;
    var e: usize = 6;
    for (sizes) |s| {
        out[e] = if (s == 256) 0 else @intCast(s);
        out[e + 1] = if (s == 256) 0 else @intCast(s);
        out[e + 2] = 0;
        out[e + 3] = 0;
        writeU16(out[e + 4 ..], 1);
        writeU16(out[e + 6 ..], 32);
        writeU32(out[e + 8 ..], @intCast(imageBytes(s)));
        writeU32(out[e + 12 ..], @intCast(off));
        e += 16;
        off += imageBytes(s);
    }

    off = 6 + 16 * sizes.len;
    for (sizes) |s| {
        const rgba = try renderRgba(alloc, s);
        defer alloc.free(rgba);

        var p = off;
        writeU32(out[p..], 40);
        writeU32(out[p + 4 ..], @intCast(s));
        writeU32(out[p + 8 ..], @intCast(s * 2));
        writeU16(out[p + 12 ..], 1);
        writeU16(out[p + 14 ..], 32);
        writeU32(out[p + 16 ..], 0);
        writeU32(out[p + 20 ..], @intCast(s * s * 4));
        // biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant
        writeU32(out[p + 24 ..], 0);
        writeU32(out[p + 28 ..], 0);
        writeU32(out[p + 32 ..], 0);
        writeU32(out[p + 36 ..], 0);
        p += 40;

        // bottom-up BGRA
        var row: usize = s;
        while (row > 0) {
            row -= 1;
            var x: usize = 0;
            while (x < s) : (x += 1) {
                const src = (row * s + x) * 4;
                out[p] = rgba[src + 2];
                out[p + 1] = rgba[src + 1];
                out[p + 2] = rgba[src];
                out[p + 3] = rgba[src + 3];
                p += 4;
            }
        }

        // AND mask: all zero, Windows uses the alpha channel at 32bpp
        const mb = maskBytes(s);
        @memset(out[p .. p + mb], 0);
        off += imageBytes(s);
    }

    const dir = std.Io.Dir.cwd();
    dir.createDirPath(io, "assets") catch {};
    try dir.writeFile(io, .{ .sub_path = "assets/tensorfold.ico", .data = out });
    std.debug.print("wrote assets/tensorfold.ico ({d} bytes, {d} sizes)\n", .{ total, sizes.len });
}
