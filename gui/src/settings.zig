//! Persisted skin choice (gui/settings.json). Deliberately tiny: the GUI must
//! keep working if the file is missing, corrupt, or names a theme that no
//! longer exists.
const std = @import("std");
const theme = @import("theme.zig");

pub const file = "settings.json";

pub fn load(io: std.Io, root: []const u8, a: std.mem.Allocator) void {
    var dir = std.Io.Dir.openDirAbsolute(io, root, .{}) catch return;
    defer dir.close(io);
    const text = dir.readFileAlloc(io, file, a, .limited(1 << 16)) catch return;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return,
    };
    const v = obj.get("theme") orelse return;
    const id = switch (v) {
        .string => |s| s,
        else => return,
    };
    if (theme.indexOf(id)) |i| theme.apply(i);
}

pub fn save(io: std.Io, root: []const u8, index: usize) void {
    var dir = std.Io.Dir.openDirAbsolute(io, root, .{}) catch return;
    defer dir.close(io);
    var buf: [128]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\n  \"theme\": \"{s}\"\n}}\n", .{theme.themes[index].id}) catch return;
    dir.writeFile(io, .{ .sub_path = file, .data = body }) catch {};
}
