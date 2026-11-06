//! Host memory: physical RAM totals from GlobalMemoryStatusEx and the serve
//! process's working set from K32GetProcessMemoryInfo.
const std = @import("std");
const w = @import("win32.zig");

pub const Host = struct {
    ok: bool = false,
    total: u64 = 0,
    avail: u64 = 0,
    load_pct: u32 = 0,
};

const ProcessCounters = extern struct {
    cb: u32 = 0,
    page_fault_count: u32 = 0,
    peak_working_set: usize = 0,
    working_set: usize = 0,
    quota_peak_paged_pool: usize = 0,
    quota_paged_pool: usize = 0,
    quota_peak_non_paged_pool: usize = 0,
    quota_non_paged_pool: usize = 0,
    pagefile_usage: usize = 0,
    peak_pagefile_usage: usize = 0,
};

extern "kernel32" fn K32GetProcessMemoryInfo(process: w.HANDLE, counters: *ProcessCounters, cb: u32) callconv(.c) w.WINBOOL;

pub fn sample() Host {
    var st: w.MEMORYSTATUSEX = .{};
    st.dwLength = @sizeOf(w.MEMORYSTATUSEX);
    if (w.GlobalMemoryStatusEx(&st) == 0) return .{};
    return .{
        .ok = true,
        .total = st.ullTotalPhys,
        .avail = st.ullAvailPhys,
        .load_pct = st.dwMemoryLoad,
    };
}

/// Working set of the process behind `handle`, or 0 when it cannot be read.
pub fn processRss(handle: ?w.HANDLE) u64 {
    const h = handle orelse return 0;
    var c: ProcessCounters = .{};
    c.cb = @sizeOf(ProcessCounters);
    if (K32GetProcessMemoryInfo(h, &c, c.cb) == 0) return 0;
    return @intCast(c.working_set);
}
