//! The TensorFold control surface: model rail on the left, live telemetry on the
//! right. Everything is drawn into a DIB back buffer; hit rects are produced by
//! the same layout code that paints.
const std = @import("std");
const w = @import("win32.zig");
const theme = @import("theme.zig");
const gfx = @import("gfx.zig");
const util = @import("util.zig");
const models = @import("models.zig");
const serve = @import("serve.zig");
const stats = @import("stats.zig");
const gpu = @import("gpu.zig");
const hostmem = @import("hostmem.zig");
const tcp = @import("tcp.zig");
const settings = @import("settings.zig");

pub const W: f32 = 1360;
pub const H: f32 = 860;

pub const Action = enum {
    none,
    close,
    minimize,
    load,
    unload,
    select_model,
    edit_port,
    edit_parallel,
    edit_context,
    edit_cache,
    rescan,
    probe,
    settings,
    theme_pick,
};

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn has(r: Rect, x: f32, y: f32) bool {
        return x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h;
    }
};

pub const Hit = struct { action: Action, index: usize, rect: Rect };

pub const EditField = enum { port, parallel, context, cache };

pub const Sample = struct { t_ms: i64, decode: f64, prefill: f64, mem: u64 };

pub const History = struct {
    items: [600]Sample = undefined,
    len: usize = 0,
    head: usize = 0,

    pub fn push(h: *History, s: Sample) void {
        if (h.len < h.items.len) {
            h.items[(h.head + h.len) % h.items.len] = s;
            h.len += 1;
        } else {
            h.items[h.head] = s;
            h.head = (h.head + 1) % h.items.len;
        }
    }

    pub fn at(h: *const History, i: usize) Sample {
        return h.items[(h.head + i) % h.items.len];
    }

    pub fn clear(h: *History) void {
        h.len = 0;
        h.head = 0;
    }
};

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    hwnd: w.HWND = null,
    scale: f32 = 1.0,
    width: f32 = W,
    height: f32 = H,

    cat: models.Catalog,
    selected: usize = 0,
    server: ?serve.Server = null,
    attached_port: ?u16 = null,
    attached_since_ms: i64 = 0,
    attach_failures: u32 = 0,
    snap: stats.Snapshot = .{},
    snap_ok: bool = false,
    last_poll_ms: i64 = 0,
    last_sample_ms: i64 = 0,
    client: std.http.Client,
    parent_env: *const std.process.Environ.Map,
    log_buf: [16 << 10]u8 = undefined,
    log_len: usize = 0,
    log_path: []const u8 = "",
    status_buf: [160]u8 = undefined,
    status_len: usize = 0,
    status_color: theme.Color = theme.ultraviolet.text_mute,

    editing: ?EditField = null,
    edit_buf: [24]u8 = undefined,
    edit_len: usize = 0,

    hover: Action = .none,
    hover_index: usize = 0,
    press: Action = .none,
    press_index: usize = 0,
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,

    history: History = .{},
    nvml: gpu.Nvml = .{},
    gpu_info: gpu.Info = .{},
    host: hostmem.Host = .{},
    proc_rss: u64 = 0,
    last_gpu_ms: i64 = 0,
    anim_decode: f64 = 0,
    anim_prefill: f64 = 0,
    anim_peak: f64 = 0,

    hits: std.ArrayList(Hit) = .empty,
    frame: std.heap.ArenaAllocator,
    snap_arena: std.heap.ArenaAllocator,
    cat_arena: *std.heap.ArenaAllocator,
    serve_arena: std.heap.ArenaAllocator,
    demo: bool = false,
    settings_open: bool = false,
    quit: bool = false,

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        root: []const u8,
        exe: []const u8,
        parent_env: *const std.process.Environ.Map,
    ) !App {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(gpa);
        var app: App = .{
            .gpa = gpa,
            .io = io,
            .cat = undefined,
            .client = .{ .allocator = gpa, .io = io },
            .parent_env = parent_env,
            .frame = std.heap.ArenaAllocator.init(gpa),
            .snap_arena = std.heap.ArenaAllocator.init(gpa),
            .cat_arena = arena,
            .serve_arena = std.heap.ArenaAllocator.init(gpa),
        };
        app.cat = models.load(io, arena.allocator(), root, exe);
        settings.load(io, root, arena.allocator());
        app.nvml = gpu.Nvml.open();
        app.gpu_info = app.nvml.sample();
        app.host = hostmem.sample();
        return app;
    }

    pub fn deinit(app: *App) void {
        if (app.server) |*s| serve.stop(app.io, s);
        app.client.deinit();
        app.hits.deinit(app.gpa);
        app.frame.deinit();
        app.nvml.close();
        app.cat_arena.deinit();
        app.gpa.destroy(app.cat_arena);
        app.serve_arena.deinit();
    }

    // ---- state -------------------------------------------------------------

    pub fn currentModel(app: *App) ?*models.Model {
        if (app.selected >= app.cat.models.len) return null;
        return &app.cat.models[app.selected];
    }

    pub fn servingIndex(app: *const App) ?usize {
        if (app.server) |s| return s.model_index;
        if (app.attached_port) |port| {
            for (app.cat.models, 0..) |m, i| if (m.profile.port == port) return i;
        }
        return null;
    }

    /// Monitor a server this app did not start (serve-bolt.bat, another port).
    pub fn attach(app: *App, port: u16) bool {
        if (app.server != null) app.stopServer();
        app.attached_port = port;
        app.attach_failures = 0;
        app.attached_since_ms = util.nowMs(app.io);
        for (app.cat.models, 0..) |m, i| if (m.profile.port == port) {
            app.selected = i;
        };
        app.history.clear();
        app.snap = .{};
        app.snap_ok = false;
        if (stats.poll(&app.client, app.snap_arena.allocator(), port, &app.snap)) {
            app.setStatus("attached to external server", theme.pal.cyan);
            return true;
        }
        app.setStatus("nothing answering on that port", theme.pal.amber);
        return false;
    }

    /// Attach to whichever configured port already answers /health.
    pub fn autoAttach(app: *App) void {
        for (app.cat.models) |m| {
            if (stats.poll(&app.client, app.snap_arena.allocator(), m.profile.port, &app.snap)) {
                _ = app.attach(m.profile.port);
                return;
            }
        }
    }

    pub fn setStatus(app: *App, msg: []const u8, c: theme.Color) void {
        const n = @min(msg.len, app.status_buf.len);
        @memcpy(app.status_buf[0..n], msg[0..n]);
        app.status_len = n;
        app.status_color = c;
    }

    pub fn loadSelected(app: *App) void {
        const m = app.currentModel() orelse return;
        if (app.server != null) {
            app.stopServer();
        }
        app.attached_port = null;
        // a server already listening on this port would load the model and then
        // die on bind; catch that before spending 30 s on the load
        var probe: stats.Snapshot = .{};
        if (stats.poll(&app.client, app.snap_arena.allocator(), m.profile.port, &probe)) {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "port {d} is already serving — unload it or change PORT", .{m.profile.port}) catch "port in use";
            app.setStatus(msg, theme.pal.amber);
            return;
        }
        _ = app.serve_arena.reset(.retain_capacity);
        const server = serve.spawn(app.io, app.serve_arena.allocator(), app.cat, app.selected, app.parent_env) catch |err| {
            var buf: [96]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "spawn failed: {s}", .{@errorName(err)}) catch "spawn failed";
            app.setStatus(msg, theme.pal.red);
            return;
        };
        app.server = server;
        app.log_path = server.log_path;
        app.history.clear();
        app.snap = .{};
        app.snap_ok = false;
        app.last_poll_ms = 0;
        app.setStatus("loading checkpoint — watch the log below", theme.pal.amber);
    }

    pub fn stopServer(app: *App) void {
        if (app.attached_port) |port| {
            app.attached_port = null;
            app.snap = .{};
            app.snap_ok = false;
            // the server was not our child, so find it by the port it listens on
            // and only terminate it when the image really is tensorfold-native
            if (tcp.isTensorfoldServer(port)) {
                if (tcp.stopServer(port)) {
                    app.setStatus("stopped the external server", theme.pal.text_mute);
                    return;
                }
            }
            app.setStatus("detached — that server keeps running", theme.pal.amber);
            return;
        }
        if (app.server) |*s| {
            serve.stop(app.io, s);
            app.setStatus("unloaded", theme.pal.text_mute);
        }
        app.server = null;
        app.snap = .{};
        app.snap_ok = false;
    }

    const ProbeCtx = struct {
        client: *std.http.Client,
        port: u16,
        model: []const u8,

        fn run(c: *ProbeCtx) void {
            _ = stats.warmup(c.client, c.port, c.model, 96);
        }
    };

    /// Fires one short completion so the counters and chart show activity.
    pub fn sendProbe(app: *App) void {
        const port: u16 = if (app.server) |s| s.port else if (app.attached_port) |p| p else {
            app.setStatus("no server to probe", theme.pal.amber);
            return;
        };
        const model_name: []const u8 = if (app.snap.model.len > 0) app.snap.model else if (app.servingIndex()) |i| app.cat.models[i].name else "";
        const ctx = app.cat_arena.allocator().create(ProbeCtx) catch return;
        ctx.* = .{ .client = &app.client, .port = port, .model = model_name };
        _ = std.Thread.spawn(.{}, ProbeCtx.run, .{ctx}) catch {};
        app.setStatus("test prompt sent — watch the counters", theme.pal.violet);
    }

    pub fn rescan(app: *App) void {
        const root = app.cat.root;
        const exe = app.cat.exe;
        _ = app.cat_arena.reset(.retain_capacity);
        app.cat = models.load(app.io, app.cat_arena.allocator(), root, exe);
        if (app.selected >= app.cat.models.len) app.selected = 0;
        app.setStatus("model folder rescanned", theme.pal.text_mute);
    }

    /// One-second housekeeping: process liveness, HTTP polling, log tail.
    pub fn tick(app: *App) void {
        _ = app.frame.reset(.retain_capacity);
        _ = app.snap_arena.reset(.retain_capacity);
        const now = util.nowMs(app.io);
        if (app.server) |*s| {
            if (serve.exited(s)) {
                if (s.state == .loading) {
                    app.setStatus("process exited while loading — see log", theme.pal.red);
                    s.state = .failed;
                } else {
                    app.setStatus("server exited", theme.pal.text_mute);
                    s.state = .stopped;
                }
                app.server = null;
                app.snap = .{};
                app.snap_ok = false;
            } else {
                const elapsed: i64 = @divTrunc(now - s.started_ms, 1000);
                if (s.state == .loading) {
                    if (stats.poll(&app.client, app.snap_arena.allocator(), s.port, &app.snap)) {
                        if (app.snap.healthy) {
                            s.state = .serving;
                            app.setStatus("serving", theme.pal.green);
                            app.history.clear();
                        }
                    } else if (elapsed > 300) {
                        s.state = .failed;
                        app.setStatus("no answer from the server after 5 min", theme.pal.red);
                    }
                }
                if (s.state == .serving) {
                    if (stats.poll(&app.client, app.snap_arena.allocator(), s.port, &app.snap)) {
                        app.snap_ok = true;
                        if (now - app.last_sample_ms >= 900) {
                            app.history.push(.{
                                .t_ms = now,
                                .decode = app.snap.decode_tps,
                                .prefill = app.snap.prefill_tps,
                                .mem = app.snap.mem_active,
                            });
                            app.last_sample_ms = now;
                        }
                        app.setStatus("serving", theme.pal.green);
                    } else {
                        app.snap_ok = false;
                        app.setStatus("server not answering — retrying", theme.pal.amber);
                    }
                }
                const tail = serve.logTail(app.io, app.frame.allocator(), s.log_path, app.log_buf.len);
                @memcpy(app.log_buf[0..tail.len], tail);
                app.log_len = tail.len;
            }
        } else if (app.attached_port) |port| {
            if (stats.poll(&app.client, app.snap_arena.allocator(), port, &app.snap)) {
                app.snap_ok = true;
                if (now - app.last_sample_ms >= 900) {
                    app.history.push(.{ .t_ms = now, .decode = app.snap.decode_tps, .prefill = app.snap.prefill_tps, .mem = app.snap.mem_active });
                    app.last_sample_ms = now;
                }
                app.setStatus("monitoring external server", theme.pal.cyan);
            } else {
                app.snap_ok = false;
                app.attach_failures += 1;
                if (app.attach_failures > 5) {
                    app.attached_port = null;
                    app.history.clear();
                    app.setStatus("external server went away — detached", theme.pal.text_mute);
                } else {
                    app.setStatus("external server not answering", theme.pal.amber);
                }
            }
            app.log_len = 0;
        } else {
            // keep the last status/log visible after a server stops
        }
        app.last_poll_ms = now;
        if (now - app.last_gpu_ms >= 2000) {
            app.gpu_info = app.nvml.sample();
            app.host = hostmem.sample();
            app.proc_rss = if (app.server) |s| hostmem.processRss(s.child.id) else 0;
            app.last_gpu_ms = now;
        }

        // ease the drawn values toward the sampled ones
        app.anim_decode += (app.snap.decode_tps - app.anim_decode) * 0.35;
        app.anim_prefill += (app.snap.prefill_tps - app.anim_prefill) * 0.35;
        app.anim_peak = @max(app.anim_peak * 0.995, app.anim_decode);
    }

    /// True while the drawn values are still easing toward the sampled ones.
    pub fn animating(app: *const App) bool {
        if (@abs(app.anim_decode - app.snap.decode_tps) > 0.3) return true;
        if (@abs(app.anim_prefill - app.snap.prefill_tps) > 1.0) return true;
        if (app.snap.fill_prompt != null) return true;
        return false;
    }

    // ---- layout ------------------------------------------------------------

    pub const RailGeom = struct {
        card_h: f32,
        gap: f32,
        cards_y: f32,
        plan_y: f32,
        plan_h: f32,
    };

    /// The rail has one fixed height, so cards and the serve plan share it:
    /// more checkpoints shrink the cards and squeeze the plan, never overlap.
    pub fn railGeom(app: *const App) RailGeom {
        const n: f32 = @floatFromInt(@max(1, app.cat.models.len));
        const top: f32 = 104;
        const bottom: f32 = 624;
        // keep at least 200px for the serve plan, whatever the checkpoint count
        const plan_min: f32 = 200;
        const room = (bottom - plan_min) - top;
        var gap: f32 = 8;
        var card_h: f32 = 112;
        if (n * (card_h + gap) > room) {
            card_h = @max(54, room / n - gap);
            if (n * (card_h + gap) > room) gap = 4;
        }
        const cards_end = top + n * (card_h + gap);
        const plan_y = cards_end + 2;
        return .{
            .card_h = card_h,
            .gap = gap,
            .cards_y = top,
            .plan_y = plan_y,
            .plan_h = @max(0, bottom - plan_y),
        };
    }

    pub fn cardRect(app: *const App, i: usize) Rect {
        const g = railGeom(app);
        return .{ .x = 24, .y = g.cards_y + @as(f32, @floatFromInt(i)) * (g.card_h + g.gap), .w = 308, .h = g.card_h };
    }

    fn loadRect(app: *const App, i: usize) Rect {
        const c = app.cardRect(i);
        const h: f32 = if (c.h >= 84) 24 else 20;
        return .{ .x = c.x + 12, .y = c.y + c.h - h - 10, .w = 100, .h = h };
    }

    fn fieldRect(i: usize) Rect {
        const x = 24 + @as(f32, @floatFromInt(i % 2)) * 154;
        const y = 688 + @as(f32, @floatFromInt(i / 2)) * 64;
        return .{ .x = x, .y = y, .w = 146, .h = 56 };
    }

    fn settingsBtn() Rect {
        return .{ .x = W - 164, .y = 12, .w = 36, .h = 28 };
    }

    fn settingsRow(i: usize) Rect {
        const px = (W - 560) / 2;
        const py = (H - 430) / 2;
        return .{ .x = px + 28, .y = py + 96 + @as(f32, @floatFromInt(i)) * 74, .w = 504, .h = 66 };
    }

    pub fn hitTest(app: *App, x: f32, y: f32) ?Hit {
        if (app.settings_open) {
            const min_r = Rect{ .x = W - 96, .y = 8, .w = 40, .h = 30 };
            if (min_r.has(x, y)) return .{ .action = .minimize, .index = 0, .rect = min_r };
            const close_r = Rect{ .x = W - 52, .y = 8, .w = 40, .h = 30 };
            if (close_r.has(x, y)) return .{ .action = .close, .index = 0, .rect = close_r };
            const sb = settingsBtn();
            if (sb.has(x, y)) return .{ .action = .settings, .index = 0, .rect = sb };
            for (theme.themes, 0..) |_, i| {
                const r = settingsRow(i);
                if (r.has(x, y)) return .{ .action = .theme_pick, .index = i, .rect = r };
            }
            return null; // click outside closes the overlay
        }
        // window chrome
        const min_r = Rect{ .x = W - 96, .y = 8, .w = 40, .h = 30 };
        if (min_r.has(x, y)) return .{ .action = .minimize, .index = 0, .rect = min_r };
        const close_r = Rect{ .x = W - 52, .y = 8, .w = 40, .h = 30 };
        if (close_r.has(x, y)) return .{ .action = .close, .index = 0, .rect = close_r };

        for (app.cat.models, 0..) |_, i| {
            const c = app.cardRect(i);
            if (app.loadRect(i).has(x, y)) {
                const serving = if (app.servingIndex()) |si| si == i else false;
                return .{ .action = if (serving) .unload else .load, .index = i, .rect = app.loadRect(i) };
            }
            if (c.has(x, y)) return .{ .action = .select_model, .index = i, .rect = c };
        }
        const fields = [_]Action{ .edit_port, .edit_parallel, .edit_context, .edit_cache };
        for (fields, 0..) |action, i| {
            if (fieldRect(i).has(x, y)) return .{ .action = action, .index = i, .rect = fieldRect(i) };
        }
        const sb = settingsBtn();
        if (sb.has(x, y)) return .{ .action = .settings, .index = 0, .rect = sb };
        const rescan_r = Rect{ .x = 24, .y = 632, .w = 308, .h = 22 };
        if (rescan_r.has(x, y)) return .{ .action = .rescan, .index = 0, .rect = rescan_r };
        const probe_r = Rect{ .x = 1236, .y = 424, .w = 96, .h = 20 };
        if (probe_r.has(x, y)) return .{ .action = .probe, .index = 0, .rect = probe_r };
        return null;
    }

    pub fn click(app: *App, x: f32, y: f32) void {
        if (app.settings_open) {
            if (app.hitTest(x, y)) |h| switch (h.action) {
                .theme_pick => {
                    app.setTheme(h.index);
                    return;
                },
                .settings => app.settings_open = false,
                .close => app.quit = true,
                .minimize => _ = w.ShowWindow(app.hwnd, w.SW_MINIMIZE),
                else => {},
            } else {
                app.settings_open = false;
            }
            return;
        }

        const hit = app.hitTest(x, y) orelse {
            app.editing = null;
            return;
        };
        switch (hit.action) {
            .close => app.quit = true,
            .minimize => _ = w.ShowWindow(app.hwnd, w.SW_MINIMIZE),
            .load => {
                app.selected = hit.index;
                app.loadSelected();
            },
            .unload => app.stopServer(),
            .settings => app.settings_open = !app.settings_open,
            .theme_pick => app.setTheme(hit.index),
            .select_model => {
                app.selected = hit.index;
                app.editing = null;
            },
            .edit_port, .edit_parallel, .edit_context, .edit_cache => {
                app.editing = switch (hit.action) {
                    .edit_port => .port,
                    .edit_parallel => .parallel,
                    .edit_context => .context,
                    else => .cache,
                };
                const m = app.currentModel() orelse return;
                const value: u32 = switch (app.editing.?) {
                    .port => m.profile.port,
                    .parallel => m.profile.parallel,
                    .context => m.profile.context,
                    .cache => m.profile.cache_gib,
                };
                const s2 = std.fmt.bufPrint(&app.edit_buf, "{d}", .{value}) catch app.edit_buf[0..0];
                app.edit_len = s2.len;
            },
            .rescan => app.rescan(),
            .probe => app.sendProbe(),
            .none => {},
        }
    }

    pub fn char(app: *App, cp: u21) void {
        const field = app.editing orelse return;
        _ = field;
        if (cp >= '0' and cp <= '9') {
            if (app.edit_len < app.edit_buf.len - 1) {
                app.edit_buf[app.edit_len] = @intCast(cp);
                app.edit_len += 1;
            }
        }
    }

    pub fn backspace(app: *App) void {
        if (app.editing == null or app.edit_len == 0) return;
        app.edit_len -= 1;
    }

    pub fn commit(app: *App) void {
        const field = app.editing orelse return;
        const value = std.fmt.parseInt(u32, app.edit_buf[0..app.edit_len], 10) catch 0;
        const m = app.currentModel() orelse {
            app.editing = null;
            return;
        };
        switch (field) {
            .port => if (value >= 1 and value <= 65535) {
                m.profile.port = @intCast(value);
            },
            .parallel => if (value >= 1 and value <= 512) {
                m.profile.parallel = value;
            },
            .context => if (value >= 512) {
                m.profile.context = value;
            },
            .cache => m.profile.cache_gib = @min(value, 256),
        }
        app.editing = null;
        models.save(app.cat_arena.allocator(), app.io, app.cat);
        app.setStatus("launch settings saved", theme.pal.text_mute);
    }

    pub fn setTheme(app: *App, i: usize) void {
        theme.apply(i);
        settings.save(app.io, app.cat.root, i);
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "skin: {s}", .{theme.themes[theme.current].name}) catch "skin changed";
        app.setStatus(msg, theme.pal.violet);
    }

    // ---- painting ----------------------------------------------------------

    fn label(app: *App, p: *gfx.Paint, s: []const u8, x: f32, y: f32) void {
        _ = app;
        p.textTracking(s, .ui_label, theme.pal.text_mute, x, y, 1);
    }

    fn chip(p: *gfx.Paint, x: f32, y: f32, text: []const u8, c: theme.Color) void {
        const tw = p.textWidth(text, .ui_small, 0) + 18;
        p.panel(x, y, tw, 20, 10, theme.over(c, theme.pal.panel, 22), theme.over(c, theme.pal.panel, 12), theme.alpha(c, 90), null);
        p.text(text, .ui_small, c, x + 9, y + 4);
    }

    fn bar(p: *gfx.Paint, r: Rect, frac: f32, c: theme.Color) void {
        const f = std.math.clamp(frac, 0.0, 1.0);
        p.panel(r.x, r.y, r.w, r.h, r.h / 2, theme.pal.panel_sunk, theme.pal.panel_sunk, theme.pal.line, null);
        if (f > 0.001) {
            p.panel(r.x, r.y, @max(r.h, r.w * f), r.h, r.h / 2, theme.alpha(c, 210), theme.alpha(c, 150), theme.alpha(c, 0), null);
        }
    }

    fn tile(app: *App, p: *gfx.Paint, r: Rect, name: []const u8, value: []const u8, c: theme.Color) void {
        _ = app;
        p.panel(r.x, r.y, r.w, r.h, 8, theme.over(c, theme.pal.panel_hi, 8), theme.pal.panel_sunk, theme.pal.line, null);
        p.textTracking(name, .ui_label, theme.pal.text_mute, r.x + 10, r.y + 9, 1);
        p.text(value, .mono_bold, c, r.x + 10, r.y + 26);
    }

    pub fn paint(app: *App, p: *gfx.Paint) void {
        _ = app.frame.reset(.retain_capacity);
        app.hits.clearRetainingCapacity();
        p.beginFrame();

        // backdrop
        p.vgrad(0, 0, W, H, theme.pal.bg_top, theme.pal.bg_bot);
        p.glow(240, 120, 520, 320, theme.pal.violet, 16);
        p.glow(1180, 780, 420, 300, theme.pal.magenta, 12);

        switch (theme.pal.texture) {
            .grid => {
                var gx: f32 = 0;
                while (gx <= W) : (gx += 28) p.line(gx, 54, gx, H, theme.alpha(theme.pal.line, 46), 1);
                var gy: f32 = 54;
                while (gy <= H) : (gy += 28) p.line(0, gy, W, gy, theme.alpha(theme.pal.line, 34), 1);
            },
            .scanlines => {
                var sy: f32 = 0;
                while (sy <= H) : (sy += 3) p.line(0, sy, W, sy, theme.alpha(theme.pal.line, 30), 1);
            },
            .none => {},
        }

        // header
        p.rect(0, 0, W, 54, theme.alpha(theme.pal.header_bar, 200));
        p.line(0, 54, W, 54, theme.pal.line, 1);
        // logo diamond
        p.glow(30, 27, 20, 20, theme.pal.violet, 60);
        p.fillCircle(30, 27, 6, theme.pal.violet);
        p.fillCircle(30, 27, 2.5, theme.pal.mark_core);
        p.text("TENSORFOLD", .display, theme.pal.text, 46, 12);
        const wordmark_w = p.textWidth("TENSORFOLD", .display, 0);
        p.textTracking("CONTROL · N1X", .ui_label, theme.pal.violet, 46 + wordmark_w + 18, 22, 2);
        if (app.server != null or app.attached_port != null) {
            const m = app.cat.models[app.servingIndex() orelse 0];
            var up_buf: [64]u8 = undefined;
            const started: i64 = if (app.server) |s| s.started_ms else app.attached_since_ms;
            const up_s: u64 = @intCast(@max(0, @divTrunc(util.nowMs(app.io) - started, 1000)));
            const up = util.fmtDuration(&up_buf, up_s);
            var head2: [192]u8 = undefined;
            const htxt = std.fmt.bufPrint(&head2, "{s}  ·  {s}  ·  {d} lanes  ·  ctx {d}  ·  up {s}", .{
                m.name,
                if (app.snap.backend.len > 0) app.snap.backend else "cuda",
                m.profile.parallel,
                m.profile.context,
                up,
            }) catch "";
            p.textFit(htxt, .ui_small, theme.pal.text_dim, 352, 20, 610);
        }

        // window buttons
        for ([_]struct { x: f32, label: []const u8, act: Action }{
            .{ .x = W - 96, .label = "—", .act = .minimize },
            .{ .x = W - 52, .label = "✕", .act = .close },
        }) |btn| {
            const hovered = app.hover == btn.act;
            p.panel(btn.x, 8, 40, 30, 8, if (hovered) theme.pal.panel_hi else theme.pal.panel, theme.pal.panel_sunk, if (hovered) theme.pal.line_hi else theme.pal.line, null);
            p.textCentered(btn.label, .ui_small, if (hovered) theme.pal.text else theme.pal.text_dim, btn.x + 20, 15);
        }

        // skin button (settings overlay)
        {
            const sb = settingsBtn();
            const hovered = app.hover == .settings or app.settings_open;
            p.panel(sb.x, sb.y, sb.w, sb.h, 8, if (hovered) theme.pal.panel_hi else theme.pal.panel, theme.pal.panel_sunk, if (hovered) theme.pal.line_hi else theme.pal.line, null);
            // three sliders as a settings glyph
            var gy: f32 = sb.y + 8;
            var k: usize = 0;
            while (k < 3) : (k += 1) {
                p.line(sb.x + 9, gy, sb.x + sb.w - 9, gy, theme.pal.text_dim, 1);
                const knob_x = sb.x + 12 + @as(f32, @floatFromInt((k * 7) % 14));
                p.fillCircle(knob_x, gy, 2.5, theme.pal.violet);
                gy += 6;
            }
        }

        // connection chip
        const state_text = if (app.attached_port != null) "ATTACHED" else if (app.server) |s| switch (s.state) {
            .loading => "LOADING",
            .serving => "SERVING",
            .failed => "FAILED",
            else => "IDLE",
        } else "IDLE";
        const state_color = if (app.attached_port != null) theme.pal.cyan else if (app.server) |s| switch (s.state) {
            .loading => theme.pal.amber,
            .serving => theme.pal.green,
            .failed => theme.pal.red,
            else => theme.pal.text_mute,
        } else theme.pal.text_mute;
        var chip_buf: [96]u8 = undefined;
        const endpoint = if (app.attached_port) |aport| std.fmt.bufPrint(&chip_buf, "{s} · 127.0.0.1:{d}", .{ state_text, aport }) catch state_text else if (app.server) |s| std.fmt.bufPrint(&chip_buf, "{s} · 127.0.0.1:{d}", .{ state_text, s.port }) catch state_text else state_text;
        const chip_track: i32 = 1;
        const cw = p.textWidth(endpoint, .ui_small, chip_track) + 46;
        p.panel(W - 176 - cw, 12, cw, 28, 14, theme.pal.panel_hi, theme.pal.panel_sunk, theme.alpha(state_color, 120), null);
        p.fillCircle(W - 176 - cw + 16, 26, 4, state_color);
        p.textTracking(endpoint, .ui_small, state_color, W - 176 - cw + 28, 19, chip_track);

        // ---- left rail -----------------------------------------------------
        p.panel(12, 62, 332, 786, 14, theme.pal.panel_hi, theme.pal.panel_sunk, theme.pal.line, null);
        app.label(p, "MODELS", 26, 76);
        var count_buf: [32]u8 = undefined;
        const count_text = std.fmt.bufPrint(&count_buf, "{d} FOUND", .{app.cat.models.len}) catch "";
        p.textRight(count_text, .ui_label, theme.pal.text_mute, 330, 76);

        const rg = railGeom(app);
        if (app.cat.models.len == 0) {
            p.text("No checkpoints found.", .ui, theme.pal.text_dim, 26, 108);
            p.text("Put a model folder under models/.", .ui_small, theme.pal.text_mute, 26, 130);
        }

        for (app.cat.models, 0..) |m, i| {
            const c = app.cardRect(i);
            const selected = app.selected == i;
            const serving = if (app.servingIndex()) |si| si == i else false;
            const loading = serving and app.server != null and app.server.?.state == .loading;
            const accent = if (loading) theme.pal.amber else if (serving) theme.pal.green else theme.pal.violet;
            const border = if (selected) theme.alpha(accent, 200) else theme.pal.line;
            p.panel(c.x, c.y, c.w, c.h, 10, if (selected) theme.pal.panel_hi else theme.pal.panel, theme.pal.panel_sunk, border, if (selected) accent else null);

            p.fillCircle(c.x + 16, c.y + 14, 4, accent);
            if (loading) p.glow(c.x + 16, c.y + 14, 12, 12, theme.pal.amber, 90);
            p.textFit(m.name, .ui_bold, theme.pal.text, c.x + 28, c.y + 5, c.w - 64);
            var port_buf: [16]u8 = undefined;
            const port_text = std.fmt.bufPrint(&port_buf, ":{d}", .{m.profile.port}) catch "";
            p.textRight(port_text, .mono, theme.pal.text_mute, c.x + c.w - 12, c.y + 5);

            if (c.h >= 92) {
                var fam_buf: [64]u8 = undefined;
                const fam = if (m.quant.len > 0)
                    std.fmt.bufPrint(&fam_buf, "{s} · {s}", .{ m.family, m.quant }) catch m.family
                else
                    m.family;
                p.textFit(fam, .ui_small, theme.pal.text_mute, c.x + 28, c.y + 23, c.w - 40);
                var size_buf: [32]u8 = undefined;
                var meta_buf: [128]u8 = undefined;
                const size = util.fmtBytes(&size_buf, m.bytes);
                const meta = std.fmt.bufPrint(&meta_buf, "{s} · {d} shards", .{ size, m.shards }) catch size;
                p.textFit(meta, .ui_small, theme.pal.text_dim, c.x + 14, c.y + 39, c.w - 28);
            }

            const br = app.loadRect(i);
            const attached = serving and app.server == null and app.attached_port != null;
            const hot = (app.hover == .load or app.hover == .unload) and app.hover_index == i;
            if (serving) {
                p.panel(br.x, br.y, br.w, br.h, 7, theme.over(theme.pal.red, theme.pal.panel, if (hot) 90 else 60), theme.pal.panel_sunk, theme.alpha(theme.pal.red, 160), null);
                p.textCentered("UNLOAD", .ui_label, theme.pal.red, br.x + br.w / 2, br.y + br.h / 2 - 5);
            } else {
                p.panel(br.x, br.y, br.w, br.h, 7, theme.alpha(theme.pal.violet, if (hot) 255 else 200), theme.alpha(theme.pal.violet_deep, 200), theme.alpha(theme.pal.violet, 255), null);
                p.textCentered("LOAD", .ui_label, theme.pal.on_accent, br.x + br.w / 2, br.y + br.h / 2 - 5);
            }

            if (c.h >= 92) {
                var state_buf: [64]u8 = undefined;
                const state_line = if (loading)
                    std.fmt.bufPrint(&state_buf, "loading · {d}s", .{@divTrunc(util.nowMs(app.io) - app.server.?.started_ms, 1000)}) catch ""
                else if (attached)
                    std.fmt.bufPrint(&state_buf, "attached · {d} lanes · ctx {d}", .{ m.profile.parallel, m.profile.context }) catch ""
                else if (serving)
                    std.fmt.bufPrint(&state_buf, "{d} lanes · ctx {d}", .{ m.profile.parallel, m.profile.context }) catch ""
                else
                    std.fmt.bufPrint(&state_buf, "{s}", .{if (m.drafter.len > 0) "drafter paired" else "no drafter"}) catch "";
                p.textFit(state_line, .ui_small, if (serving or loading) accent else theme.pal.text_mute, br.x + br.w + 8, br.y + 4, c.x + c.w - (br.x + br.w + 16));
            }
        }

        // rescan
        const rescan_hot = app.hover == .rescan;
        p.panel(24, 632, 308, 22, 6, if (rescan_hot) theme.pal.panel_hi else theme.pal.panel, theme.pal.panel_sunk, theme.pal.line, null);
        p.textCentered("RESCAN MODEL FOLDER", .ui_label, if (rescan_hot) theme.pal.violet else theme.pal.text_mute, 178, 638);

        // serve plan: fills exactly the space the cards leave
        if (rg.plan_h >= 76) {
            p.panel(24, rg.plan_y, 308, rg.plan_h, 10, theme.pal.panel, theme.pal.panel_sunk, theme.pal.line, null);
            app.label(p, "SERVE PLAN", 38, rg.plan_y + 9);
            if (app.currentModel()) |m| {
                const plan_bottom = rg.plan_y + rg.plan_h;
                var y = rg.plan_y + 25;
                const row_h: f32 = 30;
                const show_engine = rg.plan_h >= 150;
                const show_drafter = rg.plan_h >= 190;
                const show_flags = rg.plan_h >= 235;
                const show_env = rg.plan_h >= 170;

                var ep_buf: [96]u8 = undefined;
                const ep = std.fmt.bufPrint(&ep_buf, "http://127.0.0.1:{d}/v1", .{m.profile.port}) catch "";
                p.textTracking("ENDPOINT", .ui_label, theme.pal.text_mute, 38, y, 1);
                p.textFit(ep, .mono, theme.pal.cyan, 38, y + 12, 280);
                y += row_h;

                if (show_engine) {
                    p.textTracking("ENGINE", .ui_label, theme.pal.text_mute, 38, y, 1);
                    p.textFit(util.basename(app.cat.exe), .mono, theme.pal.text_dim, 38, y + 12, 280);
                    y += row_h;
                }
                if (show_drafter) {
                    p.textTracking("DRAFTER", .ui_label, theme.pal.text_mute, 38, y, 1);
                    var dr_buf: [128]u8 = undefined;
                    const dr = if (m.drafter.len > 0) std.fmt.bufPrint(&dr_buf, "{s}", .{util.basename(m.drafter)}) catch "—" else "none (no speculation)";
                    p.textFit(dr, .mono, if (m.drafter.len > 0) theme.pal.magenta else theme.pal.text_mute, 38, y + 12, 280);
                    y += row_h;
                }
                if (show_flags) {
                    p.textTracking("FLAGS", .ui_label, theme.pal.text_mute, 38, y, 1);
                    var fl_buf: [192]u8 = undefined;
                    const flags = std.fmt.bufPrint(&fl_buf, "--parallel {d} --context {d} --prompt-cache-gib {d} --dashboard", .{ m.profile.parallel, m.profile.context, m.profile.cache_gib }) catch "";
                    p.textFit(flags, .mono, theme.pal.text_dim, 38, y + 12, 280);
                    y += row_h;
                }
                if (show_env) {
                    p.textTracking("ENVIRONMENT", .ui_label, theme.pal.text_mute, 38, y, 1);
                    y += 13;
                    const room = @max(0.0, (plan_bottom - 18) - y);
                    const max_lines: usize = @intFromFloat(@min(7.0, room / 14.0));
                    if (m.profile.env.len == 0) {
                        p.text("none", .mono, theme.pal.text_mute, 38, y);
                    } else {
                        for (m.profile.env, 0..) |e, k| {
                            if (k >= max_lines) break;
                            var env_buf: [160]u8 = undefined;
                            const etxt = std.fmt.bufPrint(&env_buf, "{s}={s}", .{ e.key, if (e.value.len > 40) util.basename(e.value) else e.value }) catch "";
                            p.textFit(etxt, .mono, theme.pal.text_mute, 38, y, 280);
                            y += 14;
                        }
                    }
                }
                if ((app.server != null or app.attached_port != null) and plan_bottom - y > 14) {
                    p.text("running — unload before editing ports", .ui_small, theme.pal.amber, 38, plan_bottom - 16);
                }
            } else {
                p.text("Select a checkpoint on the left.", .ui_small, theme.pal.text_mute, 38, rg.plan_y + 30);
            }
        }

        // launch settings
        p.panel(24, 656, 308, 192, 10, theme.pal.panel, theme.pal.panel_sunk, theme.pal.line, null);
        app.label(p, "LAUNCH SETTINGS", 38, 666);
        if (app.currentModel()) |m| {
            // sit the folder name after the section label, using the rest of the
            // header row instead of right-aligning it into the label
            const label_w = p.textWidth("LAUNCH SETTINGS", .ui_label, 1);
            const name_x = 38 + label_w + 16;
            p.textFit(util.basename(m.dir), .ui_small, theme.pal.text_mute, name_x, 666, 330 - name_x);
        }

        const field_names = [_][]const u8{ "PORT", "LANES", "CONTEXT", "CACHE GiB" };
        const edit_actions = [_]Action{ .edit_port, .edit_parallel, .edit_context, .edit_cache };
        const edit_fields = [_]EditField{ .port, .parallel, .context, .cache };
        for (0..4) |i| {
            const fr = fieldRect(i);
            const field = edit_fields[i];
            const active = app.editing != null and app.editing.? == field;
            const hot = app.hover == edit_actions[i];
            p.panel(fr.x, fr.y, fr.w, fr.h, 10, if (active) theme.pal.panel_hi else theme.pal.panel, theme.pal.panel_sunk, if (active) theme.alpha(theme.pal.violet, 230) else if (hot) theme.alpha(theme.pal.violet, 120) else theme.pal.line, null);
            // label inside the field, top-left, with room under it for the value
            p.textTracking(field_names[i], .ui_label, theme.pal.text_mute, fr.x + 12, fr.y + 9, 1);

            if (active) {
                p.text(app.edit_buf[0..app.edit_len], .mono_bold, theme.pal.text, fr.x + 12, fr.y + 27);
                const caret_x = fr.x + 12 + p.textWidth(app.edit_buf[0..app.edit_len], .mono_bold, 0) + 2;
                p.line(caret_x, fr.y + 24, caret_x, fr.y + 44, theme.pal.violet, 2);
            } else if (app.currentModel()) |m| {
                var vb: [24]u8 = undefined;
                const v: u32 = switch (i) {
                    0 => m.profile.port,
                    1 => m.profile.parallel,
                    2 => m.profile.context,
                    else => m.profile.cache_gib,
                };
                const txt = std.fmt.bufPrint(&vb, "{d}", .{v}) catch "";
                p.text(txt, .mono_bold, theme.pal.text, fr.x + 12, fr.y + 27);
            }
        }

        if (app.attached_port) |port| {
            var foot_buf: [64]u8 = undefined;
            const foot = std.fmt.bufPrint(&foot_buf, "monitoring external server · {d}", .{port}) catch "";
            p.textFit(foot, .ui_small, theme.pal.cyan, 38, 828, 280);
        } else if (app.server != null) {
            p.text("server started by this GUI", .ui_small, theme.pal.text_mute, 38, 828);
        } else {
            p.text("idle — LOAD starts a server with these settings", .ui_small, theme.pal.text_mute, 38, 828);
        }

        // ---- telemetry -----------------------------------------------------
        const snap = app.snap;
        const live = app.demo or (app.snap_ok and (app.server != null or app.attached_port != null));

        // gauge
        p.panel(356, 62, 430, 332, 14, theme.pal.panel_hi, theme.pal.panel_sunk, theme.pal.line, if (live) theme.pal.violet else null);
        app.label(p, "DECODE", 374, 78);
        const mode_text = if (snap.fill_prompt != null) "PREFILL" else if (live and snap.running > 0) "DECODING" else if (live) "READY" else "IDLE";
        p.textRight(mode_text, .ui_label, if (snap.fill_prompt != null) theme.pal.cyan else if (live) theme.pal.violet else theme.pal.text_mute, 768, 78);

        const gx = 356 + 215;
        const gy = 62 + 178;
        const gr: f32 = 108;
        const max_rate: f64 = 300;
        p.glow(gx, gy, 130, 130, if (live) theme.pal.violet else theme.pal.line_hi, if (live) 26 else 12);
        p.arc(gx, gy, gr, 16, 135, 270, theme.alpha(theme.pal.mark_core, 14));
        const frac: f32 = @floatCast(std.math.clamp(app.anim_decode / max_rate, 0.0, 1.0));
        if (frac > 0.002) {
            p.arcGradient(gx, gy, gr, 16, 135, 270 * frac, theme.pal.violet, theme.accentFor(app.anim_decode));
            // tip
            const tip_a = (135.0 + 270.0 * frac) * std.math.pi / 180.0;
            const tx = gx + gr * @cos(tip_a);
            const ty = gy + gr * @sin(tip_a);
            p.glow(tx, ty, 22, 22, theme.accentFor(app.anim_decode), 110);
            p.fillCircle(tx, ty, 4, theme.pal.mark_core);
        }
        // ticks
        var t: usize = 0;
        while (t <= 4) : (t += 1) {
            const a_t = (135.0 + 270.0 * (@as(f32, @floatFromInt(t)) / 4.0)) * std.math.pi / 180.0;
            const x1 = gx + (gr - 13) * @cos(a_t);
            const y1 = gy + (gr - 13) * @sin(a_t);
            const x2 = gx + (gr - 5) * @cos(a_t);
            const y2 = gy + (gr - 5) * @sin(a_t);
            p.line(x1, y1, x2, y2, theme.alpha(theme.pal.text_dim, 90), 1);
            var tick_buf: [16]u8 = undefined;
            const lbl = std.fmt.bufPrint(&tick_buf, "{d}", .{@as(u32, @intFromFloat(max_rate * (@as(f64, @floatFromInt(t)) / 4.0)))}) catch "";
            p.textCentered(lbl, .ui_label, theme.pal.text_mute, gx + (gr + 16) * @cos(a_t), gy + (gr + 16) * @sin(a_t) - 5);
        }

        var big_buf: [24]u8 = undefined;
        const big = if (live) util.fmtF(&big_buf, app.anim_decode, 1) else "—";
        p.textCentered(big, .display, if (live) theme.pal.text else theme.pal.text_dim, gx, gy - 22);
        p.textCentered("tok/s decode", .ui_small, theme.pal.text_mute, gx, gy + 14);

        var pre_num: [24]u8 = undefined;
        var pre_line: [64]u8 = undefined;
        const pl = std.fmt.bufPrint(&pre_line, "{s} tok/s prefill", .{util.fmtInt(&pre_num, @intFromFloat(app.anim_prefill))}) catch "";
        p.textCentered(pl, .ui_small, if (snap.prefill_tps > 0) theme.pal.cyan else theme.pal.text_mute, gx, gy + 34);

        // acceptance + in-flight strip
        var acc_buf: [48]u8 = undefined;
        const acc_pct: f64 = if (snap.drafted > 0) @as(f64, @floatFromInt(snap.accepted)) / @as(f64, @floatFromInt(snap.drafted)) * 100 else 0;
        const acc = std.fmt.bufPrint(&acc_buf, "MTP {d:.0}% accepted", .{acc_pct}) catch "";
        p.textCentered(acc, .ui_small, if (acc_pct > 0) theme.pal.magenta else theme.pal.text_mute, gx, gy + 52);

        // idle: name the last measured rate instead of leaving the gauge blank
        if (!live or snap.running == 0) {
            const now_ms = util.nowMs(app.io);
            var i: usize = app.history.len;
            var last_rate: f64 = 0;
            var last_age: i64 = 0;
            while (i > 0) {
                i -= 1;
                const smp = app.history.at(i);
                if (smp.decode > 0.5) {
                    last_rate = smp.decode;
                    last_age = @divTrunc(now_ms - smp.t_ms, 1000);
                    break;
                }
            }
            if (last_rate > 0) {
                var last_buf: [64]u8 = undefined;
                var dur_buf: [32]u8 = undefined;
                const last = std.fmt.bufPrint(&last_buf, "last {d:.1} tok/s · {s} ago", .{ last_rate, util.fmtDuration(&dur_buf, @intCast(@max(0, last_age))) }) catch "";
                p.textCentered(last, .ui_small, theme.pal.text_mute, gx, gy + 70);
            }
        }

        // fill progress while prefilling
        if (snap.fill_prompt) |total| {
            const left = snap.fill_left orelse 0;
            const done: f64 = if (total > 0) 1.0 - @as(f64, @floatFromInt(left)) / @as(f64, @floatFromInt(total)) else 0;
            bar(p, .{ .x = 380, .y = 350, .w = 382, .h = 6 }, @floatCast(done), theme.pal.cyan);
        }

        // throughput chart
        p.panel(802, 62, 546, 332, 14, theme.pal.panel_hi, theme.pal.panel_sunk, theme.pal.line, null);
        app.label(p, "THROUGHPUT · 5 MIN", 820, 78);
        p.textRight("decode", .ui_label, theme.pal.violet, 1210, 78);
        p.textRight("prefill", .ui_label, theme.pal.cyan, 1330, 78);

        const plot = Rect{ .x = 820, .y = 104, .w = 470, .h = 240 };
        var peak_raw: f64 = 0;
        for (0..app.history.len) |i| peak_raw = @max(peak_raw, app.history.at(i).decode);
        const peak: f64 = @max(100, peak_raw * 1.2);
        // grid
        var g: usize = 0;
        while (g <= 4) : (g += 1) {
            const y = plot.y + plot.h * (@as(f32, @floatFromInt(g)) / 4.0);
            p.dashedLine(plot.x, y, plot.x + plot.w, y, theme.alpha(theme.pal.line_hi, 120), 1);
            var lbl_buf: [16]u8 = undefined;
            const lbl = std.fmt.bufPrint(&lbl_buf, "{d:.0}", .{peak * (1.0 - @as(f64, @floatFromInt(g)) / 4.0)}) catch "";
            p.textRight(lbl, .ui_label, theme.pal.text_mute, plot.x - 6, y - 6);
        }
        if (app.history.len >= 2) {
            const now = util.nowMs(app.io);
            var pts: std.ArrayList(w.GpPointF) = .empty;
            const arena = app.frame.allocator();
            for (0..app.history.len) |i| {
                const s = app.history.at(i);
                const age: f64 = @floatFromInt(now - s.t_ms);
                if (age > 300_000) continue;
                const x = plot.x + plot.w * (1.0 - @as(f32, @floatCast(age / 300_000.0)));
                const y = plot.y + plot.h * (1.0 - @as(f32, @floatCast(std.math.clamp(s.decode / peak, 0.0, 1.0))));
                pts.append(arena, .{ .X = x, .Y = y }) catch {};
            }
            p.clip(plot.x, plot.y, plot.w, plot.h);
            p.area(pts.items, plot.y + plot.h, theme.alpha(theme.pal.violet, 120), theme.alpha(theme.pal.violet, 0), theme.pal.violet, true);
            p.resetClip();
        } else {
            p.textCentered("no decode samples yet — load a model", .ui_small, theme.pal.text_mute, plot.x + plot.w / 2, plot.y + plot.h / 2);
        }
        p.text("5 min", .ui_label, theme.pal.text_mute, plot.x, plot.y + plot.h + 8);
        p.textRight("now", .ui_label, theme.pal.text_mute, plot.x + plot.w, plot.y + plot.h + 8);

        // chart side stats
        var now_buf: [16]u8 = undefined;
        var pk_buf: [16]u8 = undefined;
        var avg_buf: [16]u8 = undefined;
        var avg_sum: f64 = 0;
        for (0..app.history.len) |i| avg_sum += app.history.at(i).decode;
        const avg = if (app.history.len > 0) avg_sum / @as(f64, @floatFromInt(app.history.len)) else 0;
        p.text("NOW", .ui_label, theme.pal.text_mute, 1308, 112);
        p.textRight(util.fmtF(&now_buf, app.anim_decode, 1), .mono_bold, theme.pal.violet, 1332, 126);
        p.text("PEAK", .ui_label, theme.pal.text_mute, 1308, 158);
        p.textRight(util.fmtF(&pk_buf, peak_raw, 1), .mono_bold, theme.pal.magenta, 1332, 172);
        p.text("AVG", .ui_label, theme.pal.text_mute, 1308, 204);
        p.textRight(util.fmtF(&avg_buf, avg, 1), .mono_bold, theme.pal.cyan, 1332, 218);

        // memory: device (NVML) and host (Win32) side by side
        p.panel(356, 410, 430, 206, 14, theme.pal.panel_hi, theme.pal.panel_sunk, theme.pal.line, null);
        app.label(p, "MEMORY", 374, 426);
        p.textRight("DEVICE · HOST", .ui_label, theme.pal.text_mute, 768, 426);
        const gi = app.gpu_info;
        const host = app.host;

        p.textTracking("VRAM", .ui_label, theme.pal.text_mute, 374, 442, 1);
        if (gi.ok) {
            var tot_buf: [24]u8 = undefined;
            var used_buf: [24]u8 = undefined;
            var vbuf: [64]u8 = undefined;
            const vtxt = std.fmt.bufPrint(&vbuf, "{s} / {s}", .{ util.fmtGiB(&used_buf, gi.used), util.fmtGiB(&tot_buf, gi.total) }) catch "";
            p.text(vtxt, .display_small, theme.pal.text, 374, 456);
            var pct_buf: [16]u8 = undefined;
            const pct = @as(f64, @floatFromInt(gi.used)) / @as(f64, @floatFromInt(gi.total)) * 100.0;
            p.textRight(std.fmt.bufPrint(&pct_buf, "{d:.0}%", .{pct}) catch "", .mono_bold, theme.pal.violet, 556, 460);
            bar(p, .{ .x = 374, .y = 490, .w = 182, .h = 8 }, @floatCast(pct / 100.0), theme.pal.violet);
            var tel_buf: [96]u8 = undefined;
            const tel = std.fmt.bufPrint(&tel_buf, "{d}% · {d} °C · {d:.1} W", .{ gi.util_gpu, gi.temp_c, @as(f64, @floatFromInt(gi.power_mw)) / 1000.0 }) catch "";
            p.text(tel, .ui_small, theme.pal.text_dim, 374, 504);
        } else {
            p.text("—", .display_small, theme.pal.text_dim, 374, 456);
            p.text("nvml.dll did not answer", .ui_small, theme.pal.text_mute, 374, 504);
        }

        p.textTracking("SYSTEM RAM", .ui_label, theme.pal.text_mute, 596, 442, 1);
        if (host.ok) {
            var hbuf: [64]u8 = undefined;
            var ubuf: [24]u8 = undefined;
            var tbuf: [24]u8 = undefined;
            var hnum: [24]u8 = undefined;
            const used = host.total - host.avail;
            const htxt = std.fmt.bufPrint(&hbuf, "{s} / {s}", .{ util.fmtGiB(&ubuf, used), util.fmtGiB(&tbuf, host.total) }) catch "";
            p.text(htxt, .display_small, theme.pal.text, 596, 456);
            var hpct: [16]u8 = undefined;
            const host_frac = @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(@max(1, host.total)));
            p.textRight(std.fmt.bufPrint(&hpct, "{d:.0}%", .{host_frac * 100.0}) catch "", .mono_bold, theme.pal.cyan, 768, 460);
            bar(p, .{ .x = 596, .y = 490, .w = 172, .h = 8 }, @floatCast(host_frac), theme.pal.cyan);
            var cap_buf: [64]u8 = undefined;
            const cap = std.fmt.bufPrint(&cap_buf, "free {s} GiB", .{util.fmtGiB(&hnum, host.avail)}) catch "";
            p.text(cap, .ui_small, theme.pal.text_dim, 596, 504);
        } else {
            p.text("—", .display_small, theme.pal.text_dim, 596, 456);
            p.text("GlobalMemoryStatusEx failed", .ui_small, theme.pal.text_mute, 596, 504);
        }

        p.line(374, 524, 768, 524, theme.pal.line, 1);
        // left column: what the engine claims about device memory
        if (snap.mem_active > 0 or snap.mem_limit > 0) {
            var abuf: [32]u8 = undefined;
            var cbuf: [32]u8 = undefined;
            var pbuf: [32]u8 = undefined;
            var gbuf: [16]u8 = undefined;
            p.text(std.fmt.bufPrint(&abuf, "engine active {s}", .{util.fmtGiB(&gbuf, snap.mem_active)}) catch "", .mono, theme.pal.violet, 374, 532);
            p.text(std.fmt.bufPrint(&cbuf, "cache {s}", .{util.fmtGiB(&gbuf, snap.mem_cache)}) catch "", .mono, theme.pal.cyan, 374, 548);
            p.text(std.fmt.bufPrint(&pbuf, "peak {s} GiB", .{util.fmtGiB(&gbuf, snap.mem_peak)}) catch "", .mono, theme.pal.magenta, 374, 564);
        } else {
            p.text("engine reports no device memory on this backend;", .ui_small, theme.pal.text_mute, 374, 548);
            p.text("the NVML figures above are the real framebuffer.", .ui_small, theme.pal.text_mute, 374, 562);
        }

        // right column: what the serve process itself holds in host RAM
        var rss_num: [24]u8 = undefined;
        var proc_buf: [64]u8 = undefined;
        const proc = std.fmt.bufPrint(&proc_buf, "serve RSS {s}", .{util.fmtBytes(&rss_num, app.proc_rss)}) catch "";
        if (app.proc_rss > 0) {
            p.text(proc, .mono, theme.pal.magenta, 596, 532);
            var share_buf: [48]u8 = undefined;
            const share = std.fmt.bufPrint(&share_buf, "{d:.1}% of host", .{@as(f64, @floatFromInt(app.proc_rss)) / @as(f64, @floatFromInt(@max(1, host.total))) * 100.0}) catch "";
            p.text(share, .ui_small, theme.pal.text_mute, 596, 548);
        } else if (app.attached_port != null) {
            p.text("attached — RSS unknown", .ui_small, theme.pal.text_mute, 596, 532);
            p.text("(server started outside the GUI)", .ui_small, theme.pal.text_mute, 596, 548);
        } else {
            p.text("serve process not running", .ui_small, theme.pal.text_mute, 596, 532);
        }
        if (gi.ok) {
            var name_buf: [96]u8 = undefined;
            const gname = std.fmt.bufPrint(&name_buf, "{s}", .{gi.name}) catch "";
            p.textRight(gname, .ui_small, theme.pal.text_mute, 768, 584);
        }

        // tiles
        p.panel(802, 410, 546, 206, 14, theme.pal.panel_hi, theme.pal.panel_sunk, theme.pal.line, null);
        app.label(p, "LIVE COUNTERS", 820, 426);
        const probe_hot = app.hover == .probe;
        const probe_live = live or app.attached_port != null;
        p.panel(1236, 424, 96, 20, 10, if (probe_hot and probe_live) theme.alpha(theme.pal.violet, 90) else theme.pal.panel_sunk, theme.pal.panel_sunk, if (probe_live) theme.alpha(theme.pal.violet, 150) else theme.pal.line, null);
        p.textCentered("TEST PROMPT", .ui_label, if (probe_live) (if (probe_hot) theme.pal.text else theme.pal.violet) else theme.pal.text_mute, 1284, 429);
        var tvals: [8][24]u8 = undefined;
        var tnums: [8][24]u8 = undefined;
        var ttexts: [8][]const u8 = undefined;
        ttexts[0] = std.fmt.bufPrint(&tvals[0], "{d}", .{snap.running}) catch "—";
        ttexts[1] = std.fmt.bufPrint(&tvals[1], "{d}", .{snap.waiting}) catch "—";
        ttexts[2] = std.fmt.bufPrint(&tvals[2], "{s}", .{util.fmtInt(&tnums[2], snap.prompt_total)}) catch "—";
        ttexts[3] = std.fmt.bufPrint(&tvals[3], "{s}", .{util.fmtInt(&tnums[3], snap.gen_total)}) catch "—";
        ttexts[4] = std.fmt.bufPrint(&tvals[4], "{d:.0}%", .{acc_pct}) catch "—";
        ttexts[5] = std.fmt.bufPrint(&tvals[5], "{s}", .{util.fmtInt(&tnums[5], snap.rounds)}) catch "—";
        ttexts[6] = std.fmt.bufPrint(&tvals[6], "{d}%", .{gi.util_gpu}) catch "—";
        ttexts[7] = std.fmt.bufPrint(&tvals[7], "{d} °C", .{gi.temp_c}) catch "—";
        const names = [_][]const u8{ "RUNNING", "WAITING", "PROMPT TOK", "GEN TOK", "MTP ACC", "ROUNDS", "GPU UTIL", "GPU TEMP" };
        const colors = [_]theme.Color{ theme.pal.violet, theme.pal.amber, theme.pal.text_dim, theme.pal.violet, theme.pal.magenta, theme.pal.cyan, theme.pal.cyan, theme.pal.amber };
        for (0..8) |i| {
            const r = Rect{
                .x = 820 + @as(f32, @floatFromInt(i % 4)) * 130,
                .y = 444 + @as(f32, @floatFromInt(i / 4)) * 78,
                .w = 120,
                .h = 68,
            };
            const show = if (i >= 6) gi.ok else live;
            app.tile(p, r, names[i], if (show) ttexts[i] else "—", if (show) colors[i] else theme.pal.text_mute);
        }

        // log
        p.panel(356, 632, 992, 216, 14, theme.pal.panel_hi, theme.pal.panel_sunk, theme.pal.line, null);
        app.label(p, "SERVER LOG", 374, 648);
        if (app.server) |s| {
            p.textRight(s.log_path, .ui_small, theme.pal.text_mute, 1330, 648);
        } else {
            p.textRight("idle", .ui_small, theme.pal.text_mute, 1330, 648);
        }
        p.line(374, 670, 1330, 670, theme.pal.line, 1);

        const log_area = Rect{ .x = 374, .y = 676, .w = 956, .h = 160 };
        if (app.log_len == 0) {
            p.text("Serve output lands here: load progress, warnings and the request line.", .ui_small, theme.pal.text_mute, log_area.x, log_area.y + 6);
        } else {
            var lines: [14][]const u8 = undefined;
            var n: usize = 0;
            var it = std.mem.splitScalar(u8, app.log_buf[0..app.log_len], '\n');
            while (it.next()) |line| {
                const trimmed = std.mem.trimEnd(u8, line, &[_]u8{13});
                if (trimmed.len == 0) continue;
                // skip our own polling noise so load progress stays visible
                if (std.mem.indexOf(u8, trimmed, "\"GET /health") != null or
                    std.mem.indexOf(u8, trimmed, "\"GET /metrics") != null or
                    std.mem.indexOf(u8, trimmed, "\"GET /stats") != null) continue;
                if (n < lines.len) {
                    lines[n] = trimmed;
                    n += 1;
                } else {
                    std.mem.copyForwards([]const u8, lines[0 .. lines.len - 1], lines[1..]);
                    lines[lines.len - 1] = trimmed;
                }
            }
            p.clip(log_area.x, log_area.y, log_area.w, log_area.h);
            var y = log_area.y;
            for (lines[0..n], 0..) |line, i| {
                const c = if (std.mem.indexOf(u8, line, "error") != null or std.mem.indexOf(u8, line, "ERROR") != null)
                    theme.pal.red
                else if (std.mem.indexOf(u8, line, "warn") != null or std.mem.indexOf(u8, line, "WARN") != null)
                    theme.pal.amber
                else if (i == n - 1)
                    theme.pal.text
                else
                    theme.pal.text_mute;
                const max_chars: usize = 150;
                const shown = if (line.len > max_chars) line[0..max_chars] else line;
                p.textFit(shown, .mono, c, log_area.x, y, log_area.w);
                y += 11.5;
            }
            p.resetClip();
        }

        if (app.settings_open) app.paintSettings(p);
    }

    fn paintSettings(app: *App, p: *gfx.Paint) void {
        const px = (W - 560) / 2;
        const py = (H - 430) / 2;
        // the dashboard's text is queued for the end-of-frame flush; draw it now
        // so the scrim can actually cover it
        p.flushTextNow();
        // opaque scrim: the dashboard behind must not compete with the panel text
        p.rect(0, 0, W, H, theme.over(theme.pal.bg_bot, theme.rgb(0, 0, 0), 210));
        // solid body first so the gradient can never read as translucent
        p.panel(px, py, 560, 430, 16, theme.pal.panel_sunk, theme.pal.panel_sunk, theme.pal.panel_sunk, null);
        p.panel(px, py, 560, 430, 16, theme.pal.panel_hi, theme.pal.panel_sunk, theme.alpha(theme.pal.violet, 180), theme.pal.violet);
        app.label(p, "APPEARANCE", px + 28, py + 22);
        const title_w = p.textWidth("APPEARANCE", .ui_label, 1);
        p.text("skin", .ui_small, theme.pal.text_mute, px + 28 + title_w + 14, py + 24);
        p.textRight("saved to settings.json", .ui_small, theme.pal.text_mute, px + 532, py + 24);
        p.text("Pick a chassis. The window repaints immediately and the choice persists.", .ui_small, theme.pal.text_dim, px + 28, py + 50);

        for (theme.themes, 0..) |t, i| {
            const r = settingsRow(i);
            const active = theme.current == i;
            const hot = app.hover == .theme_pick and app.hover_index == i;
            p.panel(r.x, r.y, r.w, r.h, 10, if (active) theme.over(t.pal.violet, theme.pal.panel, 26) else if (hot) theme.pal.panel_hi else theme.pal.panel, theme.pal.panel_sunk, if (active) theme.alpha(t.pal.violet, 220) else theme.pal.line, null);
            var sx = r.x + 14;
            for ([_]theme.Color{ t.pal.bg_top, t.pal.panel_hi, t.pal.violet, t.pal.cyan, t.pal.magenta }) |c| {
                p.panel(sx, r.y + 13, 22, 40, 4, c, theme.alpha(c, 210), theme.pal.line, null);
                sx += 24;
            }
            p.text(t.name, .ui_bold, if (active) t.pal.violet else theme.pal.text, r.x + 150, r.y + 13);
            p.text(t.blurb, .ui_small, theme.pal.text_mute, r.x + 150, r.y + 33);
            if (active) p.textRight("ACTIVE", .ui_label, t.pal.violet, r.x + r.w - 14, r.y + 14);
        }

        p.text("Esc or click outside to close", .ui_small, theme.pal.text_mute, px + 28, py + 402);
    }
};
