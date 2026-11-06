//! Owns the tensorfold-native serve process: build argv/env, spawn with the log
//! redirected to a file, report liveness, and stop it on unload.
const std = @import("std");
const w = @import("win32.zig");
const models = @import("models.zig");
const util = @import("util.zig");

pub const State = enum { stopped, loading, serving, stopping, failed };

pub const Server = struct {
    child: std.process.Child,
    port: u16,
    model_index: usize,
    log_path: []const u8,
    started_ms: i64,
    state: State = .loading,
    note: []const u8 = "",
};

fn arg(a: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    try list.append(a, value);
}

pub fn spawn(
    io: std.Io,
    a: std.mem.Allocator,
    cat: models.Catalog,
    index: usize,
    parent_env: *const std.process.Environ.Map,
) !Server {
    const m = cat.models[index];
    var argv: std.ArrayList([]const u8) = .empty;
    try arg(a, &argv, cat.exe);
    try arg(a, &argv, "serve");
    try arg(a, &argv, m.dir);
    try arg(a, &argv, "--name");
    try arg(a, &argv, m.name);
    try arg(a, &argv, "--host");
    try arg(a, &argv, "127.0.0.1");
    try arg(a, &argv, "--port");
    try arg(a, &argv, try std.fmt.allocPrint(a, "{d}", .{m.profile.port}));
    try arg(a, &argv, "--parallel");
    try arg(a, &argv, try std.fmt.allocPrint(a, "{d}", .{m.profile.parallel}));
    try arg(a, &argv, "--context");
    try arg(a, &argv, try std.fmt.allocPrint(a, "{d}", .{m.profile.context}));
    try arg(a, &argv, "--prompt-cache-gib");
    try arg(a, &argv, try std.fmt.allocPrint(a, "{d}", .{m.profile.cache_gib}));
    try arg(a, &argv, "--dashboard");
    try arg(a, &argv, "--metrics-open");
    for (m.profile.extra_args) |extra| try arg(a, &argv, extra);

    var env = std.process.Environ.Map.init(a);
    try env.putAll(parent_env);
    try env.put("TENSORFOLD_NO_UPDATE_CHECK", "1");
    for (m.profile.env) |e| try env.put(e.key, e.value);

    const now = util.nowMs(io);
    const log_path = try std.fmt.allocPrint(a, "{s}/logs/gui-{s}-{d}.log", .{ cat.root, util.basename(m.dir), now });
    std.Io.Dir.createDirAbsolute(io, try std.fmt.allocPrint(a, "{s}/logs", .{cat.root}), std.Io.File.Permissions.default_dir) catch {};
    const sink = std.Io.Dir.createFileAbsolute(io, log_path, .{}) catch return error.NoLog;

    const child = std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .{ .file = sink },
        .stderr = .{ .file = sink },
        .create_no_window = true,
    }) catch |err| {
        sink.close(io);
        return err;
    };
    sink.close(io);
    return .{
        .child = child,
        .port = m.profile.port,
        .model_index = index,
        .log_path = log_path,
        .started_ms = now,
    };
}

/// True once the process has exited.
pub fn exited(s: *const Server) bool {
    const handle = s.child.id orelse return true;
    return w.WaitForSingleObject(handle, 0) == w.WAIT_OBJECT_0;
}

pub fn stop(io: std.Io, s: *Server) void {
    if (s.child.id) |handle| {
        _ = w.TerminateProcess(handle, 1);
        _ = s.child.wait(io) catch {};
    }
    s.state = .stopped;
}

/// Reads the tail of the serve log for the on-screen log panel.
pub fn logTail(io: std.Io, a: std.mem.Allocator, path: []const u8, max_bytes: usize) []const u8 {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return "";
    defer file.close(io);
    const len = file.length(io) catch return "";
    const take: usize = @intCast(@min(len, max_bytes));
    if (take == 0) return "";
    const buf = a.alloc(u8, take) catch return "";
    _ = file.readPositionalAll(io, buf, len - take) catch return "";
    return buf;
}
