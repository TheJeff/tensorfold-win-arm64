//! Ultraviolet palette for the TensorFold control GUI.
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

// backdrop
pub const bg_top = rgb(0x12, 0x0A, 0x1E);
pub const bg_bot = rgb(0x08, 0x04, 0x10);
pub const bg_rail = rgb(0x0D, 0x07, 0x17);
// surfaces
pub const panel = rgb(0x16, 0x0D, 0x24);
pub const panel_hi = rgb(0x1C, 0x12, 0x2E);
pub const panel_sunk = rgb(0x11, 0x09, 0x1B);
pub const line = rgb(0x2A, 0x1B, 0x3D);
pub const line_hi = rgb(0x45, 0x2C, 0x63);
// type
pub const text = rgb(0xEE, 0xE8, 0xF9);
pub const text_dim = rgb(0xA9, 0x9B, 0xC4);
pub const text_mute = rgb(0x76, 0x69, 0x93);
// accents
pub const violet = rgb(0xB5, 0x7C, 0xFF);
pub const violet_deep = rgb(0x8B, 0x5C, 0xF6);
pub const magenta = rgb(0xFF, 0x4F, 0xD8);
pub const cyan = rgb(0x5C, 0xE1, 0xFF);
pub const green = rgb(0x5E, 0xF2, 0xA0);
pub const amber = rgb(0xFF, 0xC8, 0x57);
pub const red = rgb(0xFF, 0x5C, 0x7A);

pub const ui_family = "Segoe UI";
pub const mono_family = "Cascadia Mono";
pub const mono_fallback = "Consolas";

pub fn accentFor(v: f64) Color {
    // decode rate banding: hot -> cool -> accent, same idea as the web dashboard
    if (v >= 70) return cyan;
    if (v >= 45) return violet;
    if (v >= 20) return amber;
    return red;
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
