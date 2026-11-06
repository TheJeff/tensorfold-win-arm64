//! Small formatting helpers shared by the GUI panels.
const std = @import("std");

pub fn fmtBytes(buf: []u8, bytes: u64) []const u8 {
    const gb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0);
    if (gb >= 1.0) return std.fmt.bufPrint(buf, "{d:.2} GiB", .{gb}) catch "?";
    const mb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
    return std.fmt.bufPrint(buf, "{d:.0} MiB", .{mb}) catch "?";
}

pub fn fmtGiB(buf: []u8, bytes: u64) []const u8 {
    const gb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0);
    return std.fmt.bufPrint(buf, "{d:.1}", .{gb}) catch "?";
}

/// 1234567 -> "1,234,567"
pub fn fmtInt(buf: []u8, value: u64) []const u8 {
    var digits: [24]u8 = undefined;
    const raw = std.fmt.bufPrint(&digits, "{d}", .{value}) catch return "?";
    var out: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (i > 0 and (raw.len - i) % 3 == 0) {
            if (out >= buf.len) return buf[0..out];
            buf[out] = ',';
            out += 1;
        }
        if (out >= buf.len) return buf[0..out];
        buf[out] = raw[i];
        out += 1;
    }
    return buf[0..out];
}

pub fn fmtF(buf: []u8, value: f64, decimals: usize) []const u8 {
    return switch (decimals) {
        0 => std.fmt.bufPrint(buf, "{d:.0}", .{value}) catch "?",
        1 => std.fmt.bufPrint(buf, "{d:.1}", .{value}) catch "?",
        else => std.fmt.bufPrint(buf, "{d:.2}", .{value}) catch "?",
    };
}

pub fn basename(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/' or path[i - 1] == '\\') return path[i..];
    }
    return path;
}

/// Seconds as "1h 04m" / "12m 30s" / "8s".
pub fn fmtDuration(buf: []u8, seconds: u64) []const u8 {
    if (seconds >= 3600) {
        return std.fmt.bufPrint(buf, "{d}h {d:0>2}m", .{ seconds / 3600, (seconds % 3600) / 60 }) catch "?";
    }
    if (seconds >= 60) return std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ seconds / 60, seconds % 60 }) catch "?";
    return std.fmt.bufPrint(buf, "{d}s", .{seconds}) catch "?";
}

pub fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.awake.now(io).toNanoseconds(), 1_000_000));
}
