//! Polls the local TensorFold server: /health, /stats and /metrics, then
//! reduces the replies to the numbers the dashboard draws.
const std = @import("std");

pub const Snapshot = struct {
    ok: bool = false,
    healthy: bool = false,
    model: []const u8 = "",
    version: []const u8 = "",
    backend: []const u8 = "",
    warming: bool = false,
    decode_tps: f64 = 0,
    prefill_tps: f64 = 0,
    running: u32 = 0,
    waiting: u32 = 0,
    gen_running: u64 = 0,
    prompt_total: u64 = 0,
    gen_total: u64 = 0,
    drafted: u64 = 0,
    accepted: u64 = 0,
    rounds: u64 = 0,
    mem_active: u64 = 0,
    mem_cache: u64 = 0,
    mem_peak: u64 = 0,
    mem_limit: u64 = 0,
    fill_prompt: ?u64 = null,
    fill_left: ?u64 = null,
    kv_ratio: f64 = 0,
    http_total: u64 = 0,
    ctx_window: u64 = 0,
    lanes: u64 = 0,
};

fn objGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn num(v: ?std.json.Value) f64 {
    const val = v orelse return 0;
    return switch (val) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch 0,
        else => 0,
    };
}

fn uint(v: ?std.json.Value) u64 {
    return @intFromFloat(@max(0, num(v)));
}

fn str(v: ?std.json.Value) []const u8 {
    const val = v orelse return "";
    return switch (val) {
        .string => |s| s,
        else => "",
    };
}

pub fn httpGet(client: *std.http.Client, port: u16, path: []const u8, buf: []u8) ![]const u8 {
    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}{s}", .{ port, path });
    var w = std.Io.Writer.fixed(buf);
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &w,
        .keep_alive = false,
    });
    if (@intFromEnum(res.status) < 200 or @intFromEnum(res.status) >= 300) return error.BadStatus;
    return w.buffered();
}

/// One short chat request so the dashboard has decode numbers to show.
pub fn warmup(client: *std.http.Client, port: u16, model: []const u8, max_tokens: u32) bool {
    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/chat/completions", .{port}) catch return false;
    var body_buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf,
        "{{\"model\":\"{s}\",\"messages\":[{{\"role\":\"user\",\"content\":\"Write a paragraph about the sea.\"}}],\"max_tokens\":{d},\"temperature\":0.2}}",
        .{ model, max_tokens }) catch return false;
    var out: [64 << 10]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .response_writer = &w,
        .keep_alive = false,
        .headers = .{ .content_type = .{ .override = "application/json" } },
    }) catch return false;
    return @intFromEnum(res.status) >= 200 and @intFromEnum(res.status) < 300;
}

/// Fills `out` from /health and /stats. Returns false when the server is not answering.
pub fn poll(
    client: *std.http.Client,
    a: std.mem.Allocator,
    port: u16,
    out: *Snapshot,
) bool {
    out.* = .{};

    var health_buf: [64 << 10]u8 = undefined;
    const health_body = httpGet(client, port, "/health", &health_buf) catch return false;
    const health = std.json.parseFromSliceLeaky(std.json.Value, a, health_body, .{}) catch return false;
    out.ok = true;
    out.healthy = std.mem.eql(u8, str(objGet(health, "status")), "ok");
    out.model = str(objGet(health, "model"));
    out.version = str(objGet(health, "version"));
    out.backend = str(objGet(health, "backend"));
    out.warming = switch (objGet(health, "warming") orelse std.json.Value{ .bool = false }) {
        .bool => |b| b,
        else => false,
    };
    out.lanes = uint(objGet(health, "max_batch_size"));
    if (objGet(health, "memory")) |mem| {
        out.mem_active = uint(objGet(mem, "active"));
        out.mem_cache = uint(objGet(mem, "cache"));
        out.mem_peak = uint(objGet(mem, "peak"));
        out.mem_limit = uint(objGet(mem, "limit"));
    }

    var stats_buf: [128 << 10]u8 = undefined;
    const stats_body = httpGet(client, port, "/stats?poll=1", &stats_buf) catch return true;
    const stats = std.json.parseFromSliceLeaky(std.json.Value, a, stats_body, .{}) catch return true;
    out.decode_tps = num(objGet(stats, "decode_tokens_per_second"));
    out.prefill_tps = num(objGet(stats, "prefill_tokens_per_second"));
    out.running = @intCast(@min(uint(objGet(stats, "running")), std.math.maxInt(u32)));
    out.waiting = @intCast(@min(uint(objGet(stats, "waiting")), std.math.maxInt(u32)));
    out.gen_running = uint(objGet(stats, "generation_tokens_running"));
    out.prompt_total = uint(objGet(stats, "prompt_tokens_total"));
    out.gen_total = uint(objGet(stats, "generation_tokens_total"));
    out.drafted = uint(objGet(stats, "mtp_drafted_total"));
    out.accepted = uint(objGet(stats, "mtp_accepted_total"));
    out.rounds = uint(objGet(stats, "decode_rounds_total"));
    if (objGet(stats, "fill_prompt_tokens")) |v| out.fill_prompt = uint(v);
    if (objGet(stats, "fill_tokens_left")) |v| out.fill_left = uint(v);
    if (objGet(stats, "memory")) |mem| {
        out.mem_active = uint(objGet(mem, "active"));
        out.mem_cache = uint(objGet(mem, "cache"));
        out.mem_peak = uint(objGet(mem, "peak"));
        if (objGet(mem, "limit")) |v| out.mem_limit = uint(v);
    }

    var metrics_buf: [256 << 10]u8 = undefined;
    if (httpGet(client, port, "/metrics", &metrics_buf)) |body| {
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "tensorfold:kv_cache_usage_ratio{")) {
                if (std.mem.lastIndexOfScalar(u8, line, ' ')) |sp| {
                    const v = std.fmt.parseFloat(f64, line[sp + 1 ..]) catch 0;
                    out.kv_ratio = @max(out.kv_ratio, v);
                }
            } else if (std.mem.startsWith(u8, line, "tensorfold:requests_total{")) {
                if (std.mem.lastIndexOfScalar(u8, line, ' ')) |sp| {
                    out.http_total += std.fmt.parseInt(u64, line[sp + 1 ..], 10) catch 0;
                }
            }
        }
    } else |_| {}
    return true;
}
