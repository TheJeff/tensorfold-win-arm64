const std = @import("std");
const w = @import("win32.zig");
const hostmem = @import("hostmem.zig");

pub fn main(init: std.process.Init) !void {
    _ = init;
    const h = hostmem.sample();
    std.debug.print("ok={} total={d} avail={d} load={d} err={d} sizeof={d}\n", .{ h.ok, h.total, h.avail, h.load_pct, w.GetLastError(), @sizeOf(w.MEMORYSTATUSEX) });
}
