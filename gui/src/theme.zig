//! Skinnable palettes for the TensorFold control GUI. `pal` is the live palette;
//! `themes` holds the ones the settings overlay offers.
const std = @import("std");

pub const Color = u32;

pub inline fn argb(a: u8, r: u8, g: u8, b: u8) Color {
    return (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}
pub inline fn rgb(r: u8, g: u8, b: u8) Color {
    return argb(255, r, g, b);
}
pub inline fn alpha(c: Color, a: u8) Color {
    return (c & 0x00FFFFFF) | (@as(u32, a) << 24);
}
/// Blend `c` over `under` at `a`/255, returning an opaque colour.
pub fn over(c: Color, under: Color, a: u8) Color {
    const t = @as(f32, @floatFromInt(a)) / 255.0;
    const cr: f32 = @floatFromInt((c >> 16) & 0xFF);
    const cg: f32 = @floatFromInt((c >> 8) & 0xFF);
    const cb: f32 = @floatFromInt(c & 0xFF);
    const ur: f32 = @floatFromInt((under >> 16) & 0xFF);
    const ug: f32 = @floatFromInt((under >> 8) & 0xFF);
    const ub: f32 = @floatFromInt(under & 0xFF);
    return rgb(
        @intFromFloat(cr * t + ur * (1 - t)),
        @intFromFloat(cg * t + ug * (1 - t)),
        @intFromFloat(cb * t + ub * (1 - t)),
    );
}

pub const Texture = enum { none, grid, scanlines };

pub const Palette = struct {
    bg_top: Color,
    bg_bot: Color,
    bg_rail: Color,
    panel: Color,
    panel_hi: Color,
    panel_sunk: Color,
    line: Color,
    line_hi: Color,
    text: Color,
    text_dim: Color,
    text_mute: Color,
    violet: Color,
    violet_deep: Color,
    magenta: Color,
    cyan: Color,
    green: Color,
    amber: Color,
    red: Color,
    header_bar: Color,
    on_accent: Color,
    mark_core: Color,
    texture: Texture,
};

pub const Theme = struct {
    id: []const u8,
    name: []const u8,
    blurb: []const u8,
    pal: Palette,
};

pub const ultraviolet = Palette{
    .bg_top = rgb(0x12, 0x0A, 0x1E),
    .bg_bot = rgb(0x08, 0x04, 0x10),
    .bg_rail = rgb(0x0D, 0x07, 0x17),
    .panel = rgb(0x16, 0x0D, 0x24),
    .panel_hi = rgb(0x1C, 0x12, 0x2E),
    .panel_sunk = rgb(0x11, 0x09, 0x1B),
    .line = rgb(0x2A, 0x1B, 0x3D),
    .line_hi = rgb(0x45, 0x2C, 0x63),
    .text = rgb(0xEE, 0xE8, 0xF9),
    .text_dim = rgb(0xA9, 0x9B, 0xC4),
    .text_mute = rgb(0x76, 0x69, 0x93),
    .violet = rgb(0xB5, 0x7C, 0xFF),
    .violet_deep = rgb(0x8B, 0x5C, 0xF6),
    .magenta = rgb(0xFF, 0x4F, 0xD8),
    .cyan = rgb(0x5C, 0xE1, 0xFF),
    .green = rgb(0x5E, 0xF2, 0xA0),
    .amber = rgb(0xFF, 0xC8, 0x57),
    .red = rgb(0xFF, 0x5C, 0x7A),
    .header_bar = rgb(8, 4, 16),
    .on_accent = rgb(18, 10, 30),
    .mark_core = rgb(250, 245, 255),
    .texture = .none,
};

/// Militech: olive-drab chassis, brass and gold instrumentation, hazard yellow.
pub const militech = Palette{
    .bg_top = rgb(0x10, 0x16, 0x10),
    .bg_bot = rgb(0x07, 0x0A, 0x07),
    .bg_rail = rgb(0x0B, 0x10, 0x0B),
    .panel = rgb(0x15, 0x1A, 0x13),
    .panel_hi = rgb(0x1F, 0x25, 0x19),
    .panel_sunk = rgb(0x0E, 0x13, 0x10),
    .line = rgb(0x2C, 0x33, 0x27),
    .line_hi = rgb(0x4A, 0x52, 0x3C),
    .text = rgb(0xED, 0xE8, 0xD2),
    .text_dim = rgb(0xB9, 0xB7, 0xA0),
    .text_mute = rgb(0x8A, 0x8C, 0x77),
    .violet = rgb(0xC9, 0xA2, 0x27), // gold
    .violet_deep = rgb(0x8C, 0x6E, 0x1A),
    .magenta = rgb(0xE8, 0xC7, 0x4B), // hazard yellow
    .cyan = rgb(0x8F, 0xBF, 0x4A), // service green
    .green = rgb(0xA9, 0xCE, 0x5E),
    .amber = rgb(0xE2, 0xA9, 0x3A),
    .red = rgb(0xD6, 0x5B, 0x3F),
    .header_bar = rgb(9, 12, 8),
    .on_accent = rgb(14, 16, 10),
    .mark_core = rgb(0xFF, 0xF4, 0xC2),
    .texture = .grid,
};

/// Phosphor amber terminal.
pub const amber = Palette{
    .bg_top = rgb(0x0A, 0x07, 0x05),
    .bg_bot = rgb(0x05, 0x03, 0x02),
    .bg_rail = rgb(0x08, 0x05, 0x03),
    .panel = rgb(0x14, 0x10, 0x08),
    .panel_hi = rgb(0x1C, 0x16, 0x0B),
    .panel_sunk = rgb(0x0D, 0x0A, 0x06),
    .line = rgb(0x33, 0x27, 0x14),
    .line_hi = rgb(0x55, 0x40, 0x20),
    .text = rgb(0xF0, 0xD9, 0xA8),
    .text_dim = rgb(0xC2, 0xA6, 0x74),
    .text_mute = rgb(0x8C, 0x75, 0x4E),
    .violet = rgb(0xFF, 0xB0, 0x00),
    .violet_deep = rgb(0xC2, 0x7C, 0x00),
    .magenta = rgb(0xFF, 0xD2, 0x4A),
    .cyan = rgb(0xFF, 0xE0, 0x8A),
    .green = rgb(0x9B, 0xD3, 0x5A),
    .amber = rgb(0xFF, 0xC8, 0x57),
    .red = rgb(0xFF, 0x4A, 0x2E),
    .header_bar = rgb(6, 4, 2),
    .on_accent = rgb(12, 8, 4),
    .mark_core = rgb(0xFF, 0xF3, 0xD0),
    .texture = .scanlines,
};

/// Cold instrumentation: slate chassis, ice blue.
pub const ice = Palette{
    .bg_top = rgb(0x06, 0x0A, 0x10),
    .bg_bot = rgb(0x03, 0x05, 0x09),
    .bg_rail = rgb(0x08, 0x0C, 0x13),
    .panel = rgb(0x0D, 0x14, 0x1D),
    .panel_hi = rgb(0x14, 0x1D, 0x29),
    .panel_sunk = rgb(0x09, 0x0F, 0x17),
    .line = rgb(0x1E, 0x2B, 0x3A),
    .line_hi = rgb(0x33, 0x4A, 0x63),
    .text = rgb(0xE8, 0xF2, 0xFF),
    .text_dim = rgb(0xA3, 0xBC, 0xD4),
    .text_mute = rgb(0x6C, 0x82, 0x9B),
    .violet = rgb(0x7F, 0xD4, 0xFF),
    .violet_deep = rgb(0x4E, 0xA6, 0xD8),
    .magenta = rgb(0xFF, 0x6F, 0xB5),
    .cyan = rgb(0x7F, 0xFF, 0xE8),
    .green = rgb(0x6E, 0xF0, 0xA0),
    .amber = rgb(0xFF, 0xD1, 0x66),
    .red = rgb(0xFF, 0x5C, 0x6C),
    .header_bar = rgb(4, 7, 11),
    .on_accent = rgb(6, 12, 20),
    .mark_core = rgb(240, 250, 255),
    .texture = .none,
};

pub const themes = [_]Theme{
    .{ .id = "ultraviolet", .name = "ULTRAVIOLET", .blurb = "violet / magenta neon", .pal = ultraviolet },
    .{ .id = "militech", .name = "MILITECH", .blurb = "olive drab, brass and hazard gold", .pal = militech },
    .{ .id = "amber", .name = "PHOSPHOR", .blurb = "amber terminal, scanlines", .pal = amber },
    .{ .id = "ice", .name = "ICE", .blurb = "slate chassis, cold blue", .pal = ice },
};

pub var pal: Palette = ultraviolet;
pub var current: usize = 0;

pub fn apply(i: usize) void {
    current = i % themes.len;
    pal = themes[current].pal;
}

pub fn indexOf(id: []const u8) ?usize {
    for (themes, 0..) |t, i| if (std.mem.eql(u8, t.id, id)) return i;
    return null;
}

pub const ui_family = "Segoe UI";
pub const mono_family = "Cascadia Mono";
pub const mono_fallback = "Consolas";

pub fn accentFor(v: f64) Color {
    // decode rate banding: hot -> cool -> accent, same idea as the web dashboard
    if (v >= 70) return pal.cyan;
    if (v >= 45) return pal.violet;
    if (v >= 20) return pal.amber;
    return pal.red;
}

pub const Font = enum { ui, display, display_small, mono, mono_bold, ui_bold, ui_small, ui_label };

pub fn fontSpec(f: Font) struct { fam: []const u8, px: f32, bold: bool, tracking: i32 } {
    return switch (f) {
        .ui => .{ .fam = ui_family, .px = 13, .bold = false, .tracking = 0 },
        .display => .{ .fam = ui_family, .px = 26, .bold = true, .tracking = 0 },
        .display_small => .{ .fam = ui_family, .px = 20, .bold = true, .tracking = 0 },
        .mono => .{ .fam = mono_family, .px = 13, .bold = false, .tracking = 0 },
        .mono_bold => .{ .fam = mono_family, .px = 13, .bold = true, .tracking = 0 },
        .ui_bold => .{ .fam = ui_family, .px = 13, .bold = true, .tracking = 0 },
        .ui_small => .{ .fam = ui_family, .px = 11, .bold = false, .tracking = 0 },
        .ui_label => .{ .fam = ui_family, .px = 10, .bold = false, .tracking = 1 },
    };
}
