//! GPU telemetry through NVML (nvml.dll ships with the driver). Optional: if
//! NVML is missing or refuses, the panel falls back to what the engine reports.
const std = @import("std");
const w = @import("win32.zig");

const Device = ?*anyopaque;

pub const Info = struct {
    ok: bool = false,
    name: []const u8 = "",
    total: u64 = 0,
    used: u64 = 0,
    util_gpu: u32 = 0,
    util_mem: u32 = 0,
    temp_c: u32 = 0,
    power_mw: u32 = 0,
};

const MemoryV2 = extern struct { version: u32 = 0, total: u64 = 0, reserved: u64 = 0, free: u64 = 0, used: u64 = 0 };
const MemoryV1 = extern struct { version: u32 = 0, total: u64 = 0, free: u64 = 0, used: u64 = 0 };
const Utilization = extern struct { gpu: u32 = 0, memory: u32 = 0 };

fn sym(comptime T: type, lib: w.HMODULE, comptime name: [:0]const u8) ?T {
    const p = w.GetProcAddress(lib, name.ptr) orelse return null;
    return @ptrCast(@alignCast(p));
}

pub const Nvml = struct {
    lib: w.HMODULE = null,
    init: ?*const fn () callconv(.c) c_int = null,
    shutdown: ?*const fn () callconv(.c) c_int = null,
    handle: ?*const fn (u32, *Device) callconv(.c) c_int = null,
    meminfo_v2: ?*const fn (Device, *MemoryV2) callconv(.c) c_int = null,
    meminfo_v1: ?*const fn (Device, *MemoryV1) callconv(.c) c_int = null,
    util: ?*const fn (Device, *Utilization) callconv(.c) c_int = null,
    getname: ?*const fn (Device, [*]u8, u32) callconv(.c) c_int = null,
    temp: ?*const fn (Device, u32, *u32) callconv(.c) c_int = null,
    power: ?*const fn (Device, *u32) callconv(.c) c_int = null,
    device: Device = null,
    name_buf: [96]u8 = undefined,
    name_len: usize = 0,

    pub fn open() Nvml {
        var self: Nvml = .{};
        const name = [_]u16{ 'n', 'v', 'm', 'l', '.', 'd', 'l', 'l', 0 };
        const lib = w.LoadLibraryW(&name) orelse return self;
        self.lib = lib;
        self.init = sym(@TypeOf(self.init.?), lib, "nvmlInit_v2");
        self.shutdown = sym(@TypeOf(self.shutdown.?), lib, "nvmlShutdown");
        self.handle = sym(@TypeOf(self.handle.?), lib, "nvmlDeviceGetHandleByIndex_v2");
        self.meminfo_v2 = sym(@TypeOf(self.meminfo_v2.?), lib, "nvmlDeviceGetMemoryInfo_v2");
        self.meminfo_v1 = sym(@TypeOf(self.meminfo_v1.?), lib, "nvmlDeviceGetMemoryInfo");
        self.util = sym(@TypeOf(self.util.?), lib, "nvmlDeviceGetUtilizationRates");
        self.getname = sym(@TypeOf(self.getname.?), lib, "nvmlDeviceGetName");
        self.temp = sym(@TypeOf(self.temp.?), lib, "nvmlDeviceGetTemperature");
        self.power = sym(@TypeOf(self.power.?), lib, "nvmlDeviceGetPowerUsage");
        if (self.init) |f| {
            if (f() != 0) return self;
        } else return self;
        if (self.handle) |f| {
            if (f(0, &self.device) != 0) return self;
        } else return self;
        if (self.getname) |f| {
            var buf: [96]u8 = undefined;
            if (f(self.device, &buf, buf.len) == 0) {
                const len = std.mem.indexOfScalar(u8, &buf, 0) orelse buf.len;
                @memcpy(self.name_buf[0..len], buf[0..len]);
                self.name_len = len;
            }
        }
        return self;
    }

    pub fn close(self: *Nvml) void {
        if (self.shutdown) |f| _ = f();
        if (self.lib) |lib| _ = w.FreeLibrary(lib);
        self.lib = null;
    }

    pub fn sample(self: *Nvml) Info {
        var out: Info = .{};
        if (self.lib == null or self.device == null) return out;
        var total: u64 = 0;
        var used: u64 = 0;
        if (self.meminfo_v2) |f| {
            var m: MemoryV2 = .{};
            m.version = @sizeOf(MemoryV2) | (@as(u32, 2) << 24);
            if (f(self.device, &m) == 0) {
                total = m.total;
                used = m.used;
            }
        }
        if (total == 0) {
            if (self.meminfo_v1) |f| {
                var m: MemoryV1 = .{};
                if (f(self.device, &m) == 0) {
                    total = m.total;
                    used = m.used;
                }
            }
        }
        if (total == 0) return out;
        out.ok = true;
        out.name = self.name_buf[0..self.name_len];
        out.total = total;
        out.used = used;
        var u: Utilization = .{};
        if (self.util) |f| {
            if (f(self.device, &u) == 0) {
                out.util_gpu = u.gpu;
                out.util_mem = u.memory;
            }
        }
        var t: u32 = 0;
        if (self.temp) |f| {
            if (f(self.device, 0, &t) == 0) out.temp_c = t;
        }
        var p: u32 = 0;
        if (self.power) |f| {
            if (f(self.device, &p) == 0) out.power_mw = p;
        }
        return out;
    }
};
