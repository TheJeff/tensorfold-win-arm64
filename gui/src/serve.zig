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

/// The values a template token may name. Numbers are formatted once here so fill() stays
/// a pure string operation.
const Ctx = struct {
    dir: []const u8,
    name: []const u8,
    root: []const u8,
    port: []const u8,
    parallel: []const u8,
    context: []const u8,
    cache_gib: []const u8,

    fn value(c: Ctx, key: []const u8) ?[]const u8 {
        const table = .{
            .{ "dir", c.dir },           .{ "name", c.name },
            .{ "root", c.root },         .{ "port", c.port },
            .{ "parallel", c.parallel }, .{ "context", c.context },
            .{ "cache_gib", c.cache_gib },
        };
        inline for (table) |row| {
            if (std.mem.eql(u8, key, row[0])) return row[1];
        }
        return null;
    }
};

fn ctxFor(a: std.mem.Allocator, cat: models.Catalog, m: models.Model) !Ctx {
    return .{
        .dir = m.dir,
        .name = m.name,
        .root = cat.root,
        .port = try std.fmt.allocPrint(a, "{d}", .{m.profile.port}),
        .parallel = try std.fmt.allocPrint(a, "{d}", .{m.profile.parallel}),
        .context = try std.fmt.allocPrint(a, "{d}", .{m.profile.context}),
        .cache_gib = try std.fmt.allocPrint(a, "{d}", .{m.profile.cache_gib}),
    };
}

/// Appends one template token to the argv. An unknown {token} is left as its own text, so a
/// typo surfaces as a rejected argument in the log rather than vanishing.
///
/// This appends rather than returning `&.{...}`: an array literal built here lives in this
/// frame, so handing back a pointer to it left the caller reading a dead slice header. That
/// survived a Debug build and segfaulted inside CreateProcess in ReleaseFast -- the LOAD
/// button did nothing because the GUI died on the click.
fn fillInto(a: std.mem.Allocator, argv: *std.ArrayList([]const u8), tok: []const u8, c: Ctx) !void {
    if (std.mem.indexOfScalar(u8, tok, '{') == null) return argv.append(a, tok);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < tok.len) {
        if (tok[i] == '{') {
            if (std.mem.indexOfScalar(u8, tok[i..], '}')) |close| {
                if (close > 1) {
                    if (c.value(tok[i + 1 .. i + close])) |v| {
                        try out.appendSlice(a, v);
                        i += close + 1;
                        continue;
                    }
                }
            }
        }
        try out.append(a, tok[i]);
        i += 1;
    }
    return argv.append(a, out.items);
}

/// The command this GUI would run: the engine binary, then the template -- the model's
/// own argv if it carries one, otherwise the catalog's -- with placeholders filled and
/// {extra_args} expanded in place.
pub fn buildArgv(a: std.mem.Allocator, cat: models.Catalog, m: models.Model) ![]const []const u8 {
    const tmpl = if (m.profile.argv.len > 0) m.profile.argv else cat.serve_argv;
    const c = try ctxFor(a, cat, m);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, cat.exe);
    for (tmpl) |tok| {
        if (std.mem.eql(u8, tok, "{extra_args}")) {
            for (m.profile.extra_args) |x| try argv.append(a, x);
            continue;
        }
        try fillInto(a, &argv, tok, c);
    }
    return argv.items;
}

/// The whole command as one string, for the log panel: what the UI shows is literally
/// what gets spawned.
pub fn planText(a: std.mem.Allocator, cat: models.Catalog, m: models.Model) ![]const u8 {
    const argv = try buildArgv(a, cat, m);
    var out: std.ArrayList(u8) = .empty;
    for (argv, 0..) |t, i| {
        if (i > 0) try out.append(a, ' ');
        if (std.mem.indexOfScalar(u8, t, ' ') != null) {
            try out.append(a, '"');
            try out.appendSlice(a, t);
            try out.append(a, '"');
        } else {
            try out.appendSlice(a, t);
        }
    }
    return out.items;
}

/// Just the --options, which is what the FLAGS row has room for. --name and its value are
/// skipped: the card above already shows the name. This runs on every paint, so it writes
/// into the caller's buffer instead of allocating 60 times a second.
pub fn flagsBuf(buf: []u8, cat: models.Catalog, m: models.Model) []const u8 {
    var fba = std.heap.FixedBufferAllocator.init(buf);
    const a = fba.allocator();
    const argv = buildArgv(a, cat, m) catch return "";
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 1;
    var first = true;
    while (i < argv.len) {
        const t = argv[i];
        const is_flag = t.len > 1 and t[0] == '-' and t[1] == '-';
        if (!is_flag) {
            i += 1;
            continue;
        }
        if (!first) out.append(a, ' ') catch break;
        first = false;
        out.appendSlice(a, t) catch break;
        i += 1;
        if (std.mem.eql(u8, t, "--name")) continue; // its value is a name, not a flag
        if (i < argv.len) {
            const v = argv[i];
            if (!(v.len > 1 and v[0] == '-' and v[1] == '-')) {
                out.append(a, ' ') catch break;
                out.appendSlice(a, v) catch break;
                i += 1;
            }
        }
    }
    return out.items;
}

pub fn spawn(
    io: std.Io,
    a: std.mem.Allocator,
    cat: models.Catalog,
    index: usize,
    parent_env: *const std.process.Environ.Map,
) !Server {
    const m = cat.models[index];
    const argv = try buildArgv(a, cat, m);

    var env = std.process.Environ.Map.init(a);
    try env.putAll(parent_env);
    try env.put("TENSORFOLD_NO_UPDATE_CHECK", "1");
    for (m.profile.env) |e| try env.put(e.key, e.value);

    const now = util.nowMs(io);
    const log_path = try std.fmt.allocPrint(a, "{s}/logs/gui-{s}-{d}.log", .{ cat.root, util.basename(m.dir), now });
    std.Io.Dir.createDirAbsolute(io, try std.fmt.allocPrint(a, "{s}/logs", .{cat.root}), std.Io.File.Permissions.default_dir) catch {};
    const sink = std.Io.Dir.createFileAbsolute(io, log_path, .{}) catch return error.NoLog;

    const child = std.process.spawn(io, .{
        .argv = argv,
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

/// The engine binary's own version, asked once at startup: `tensorfold-native --version`
/// prints `tensorfold-native 1.2.6`, and the header shows what is installed beside what the
/// running server reports. Empty when the probe fails, so the UI shows nothing rather than a
/// stale guess.
pub fn engineVersion(io: std.Io, a: std.mem.Allocator, exe: []const u8, root: []const u8, parent_env: *const std.process.Environ.Map) []const u8 {
    std.Io.Dir.createDirAbsolute(io, std.fmt.allocPrint(a, "{s}/logs", .{root}) catch return "", std.Io.File.Permissions.default_dir) catch {};
    const out_path = std.fmt.allocPrint(a, "{s}/logs/.engine-version.txt", .{root}) catch return "";
    const sink = std.Io.Dir.createFileAbsolute(io, out_path, .{ .truncate = true }) catch return "";
    var child = std.process.spawn(io, .{
        .argv = &.{ exe, "--version" },
        .environ_map = parent_env,
        .stdin = .ignore,
        .stdout = .{ .file = sink },
        .stderr = .{ .file = sink },
        .create_no_window = true,
    }) catch {
        sink.close(io);
        return "";
    };
    sink.close(io);
    _ = child.wait(io) catch {};

    const file = std.Io.Dir.openFileAbsolute(io, out_path, .{}) catch return "";
    defer file.close(io);
    var buf: [256]u8 = undefined;
    const n = file.readPositionalAll(io, &buf, 0) catch return "";
    const text = std.mem.trim(u8, buf[0..n], " \t\r\n");
    // "tensorfold-native 1.2.6" -> "1.2.6"; an unexpected shape is shown as-is, truncated by the caller
    const version = if (std.mem.lastIndexOfScalar(u8, text, ' ')) |sp| text[sp + 1 ..] else text;
    return a.dupe(u8, version) catch "";
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
