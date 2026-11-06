const std = @import("std");

/// Maps a listening TCP port to the owning process so an attached server can be
/// stopped by the GUI even though it was not spawned as a child. Only used for
/// servers the GUI did not start; the image name is checked before killing.

const MIB_TCPROW_OWNER_PID = extern struct {
    dwState: u32 = 0,
    dwLocalAddr: u32 = 0,
    dwLocalPort: u32 = 0,
    dwRemoteAddr: u32 = 0,
    dwRemotePort: u32 = 0,
    dwOwningPid: u32 = 0,
};

const MIB_TCPTABLE_OWNER_PID = extern struct {
    dwNumEntries: u32 = 0,
    table: [1]MIB_TCPROW_OWNER_PID = undefined,
};

extern "iphlpapi" fn GetExtendedTcpTable(
    pTcpTable: ?*anyopaque,
    pdwSize: *u32,
    bOrder: c_int,
    ulAf: u32,
    tableClass: u32,
    reserved: u32,
) callconv(.winapi) u32;

extern "kernel32" fn OpenProcess(access: u32, inherit: c_int, pid: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn TerminateProcess(h: *anyopaque, code: u32) callconv(.winapi) c_int;
extern "kernel32" fn CloseHandle(h: *anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn QueryFullProcessImageNameW(h: *anyopaque, flags: u32, buf: [*]u16, cap: *u32) callconv(.winapi) c_int;

const AF_INET: u32 = 2;
const TCP_TABLE_OWNER_PID_LISTENER: u32 = 3;
const ERROR_INSUFFICIENT_BUFFER: u32 = 122;
const PROCESS_TERMINATE: u32 = 0x0001;
const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;

pub fn pidOnPort(port: u16) ?u32 {
    var size: u32 = 0;
    var rc = GetExtendedTcpTable(null, &size, 1, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 0);
    if (rc != ERROR_INSUFFICIENT_BUFFER) return null;

    var buf: [96 * 1024]u8 align(8) = undefined;
    if (size > buf.len) return null;
    rc = GetExtendedTcpTable(&buf, &size, 1, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 0);
    if (rc != 0) return null;

    const table: *const MIB_TCPTABLE_OWNER_PID = @ptrCast(@alignCast(&buf));
    const rows: [*]const MIB_TCPROW_OWNER_PID = @ptrCast(&table.table);
    var i: usize = 0;
    while (i < table.dwNumEntries) : (i += 1) {
        const low: u32 = rows[i].dwLocalPort & 0xffff;
        const host_port: u16 = @intCast((low >> 8) | ((low & 0xff) << 8));
        if (host_port == port) return rows[i].dwOwningPid;
    }
    return null;
}

pub fn imageName(pid: u32, out: []u16) ?[]const u16 {
    const h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return null;
    defer _ = CloseHandle(h);
    var cap: u32 = @intCast(out.len);
    if (QueryFullProcessImageNameW(h, 0, out.ptr, &cap) == 0) return null;
    return out[0..cap];
}

pub fn terminate(pid: u32) bool {
    const h = OpenProcess(PROCESS_TERMINATE, 0, pid) orelse return false;
    defer _ = CloseHandle(h);
    return TerminateProcess(h, 0) != 0;
}

/// True when the process listening on `port` is a TensorFold server. Refuses to
/// touch anything else, so an unrelated program on that port survives.
pub fn isTensorfoldServer(port: u16) bool {
    const pid = pidOnPort(port) orelse return false;
    var name_buf: [512]u16 = undefined;
    const name = imageName(pid, &name_buf) orelse return false;
    var utf8: [1024]u8 = undefined;
    const n = std.unicode.utf16LeToUtf8(&utf8, name) catch return false;
    return std.mem.indexOf(u8, utf8[0..n], "tensorfold-native") != null;
}

pub fn stopServer(port: u16) bool {
    const pid = pidOnPort(port) orelse return false;
    return terminate(pid);
}
