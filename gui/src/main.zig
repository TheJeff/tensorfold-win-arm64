//! tensorfold-gui: a native Win32 control surface for the local TensorFold
//! server (model load/unload + live telemetry). No runtime dependencies.
const std = @import("std");
const w = @import("win32.zig");
const theme = @import("theme.zig");
const gfx = @import("gfx.zig");
const app_mod = @import("app.zig");
const util = @import("util.zig");
const stats = @import("stats.zig");

var g_app: ?*app_mod.App = null;
var g_paint: ?gfx.Paint = null;
var g_scale: f32 = 1.0;
var g_token: usize = 0;

fn wstr(comptime s: []const u8) [s.len:0]u16 {
    var out: [s.len:0]u16 = undefined;
    for (s, 0..) |ch, i| out[i] = ch;
    out[s.len] = 0;
    return out;
}

fn u16ToUtf8(a: std.mem.Allocator, s: []const u16) []const u8 {
    return std.unicode.utf16LeToUtf8Alloc(a, s) catch "";
}

/// Windows paths in models.json are written with forward slashes so the file
/// stays valid JSON without escaping.
fn toSlashes(a: std.mem.Allocator, path: []const u8) []const u8 {
    const out = a.dupe(u8, path) catch return path;
    for (out) |*ch| if (ch.* == 0x5C) {
        ch.* = '/';
    };
    return out;
}

/// Finds the repo root: TENSORFOLD_ROOT wins, then the exe path, then cwd.
fn findRoot(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) []const u8 {
    if (env.get("TENSORFOLD_ROOT")) |r| {
        if (r.len > 0) return r;
    }
    var path_buf: [1024]u16 = undefined;
    const n = w.GetModuleFileNameW(null, &path_buf, path_buf.len);
    const exe_path = u16ToUtf8(a, path_buf[0..n]);
    var dir = std.fs.path.dirname(exe_path) orelse ".";
    var level: usize = 0;
    while (level < 6) : (level += 1) {
        var probe: [1024]u8 = undefined;
        const models_path = std.fmt.bufPrint(&probe, "{s}/models", .{dir}) catch break;
        var has_models = false;
        if (std.Io.Dir.openDirAbsolute(io, models_path, .{})) |d| {
            var dd = d;
            dd.close(io);
            has_models = true;
        } else |_| {}
        var probe2: [1024]u8 = undefined;
        const tf_path = std.fmt.bufPrint(&probe2, "{s}/tensorfold", .{dir}) catch break;
        var has_tf = false;
        if (std.Io.Dir.openDirAbsolute(io, tf_path, .{})) |d2| {
            var dd2 = d2;
            dd2.close(io);
            has_tf = true;
        } else |_| {}
        if (has_models and has_tf) return toSlashes(a, dir);
        dir = std.fs.path.dirname(dir) orelse break;
    }
    var cwd_buf: [1024]u8 = undefined;
    const n2 = std.Io.Dir.cwd().realPath(io, &cwd_buf) catch return ".";
    return a.dupe(u8, cwd_buf[0..n2]) catch ".";
}

fn nchittest(hwnd: w.HWND, lp: w.LPARAM) w.LRESULT {
    var pt: w.POINT = .{ .x = @intCast(@as(i16, @truncate(lp))), .y = @intCast(@as(i16, @truncate(lp >> 16))) };
    _ = w.ScreenToClient(hwnd, &pt);
    const x: f32 = @floatFromInt(pt.x);
    const y: f32 = @floatFromInt(pt.y);
    const width: f32 = @as(f32, @floatFromInt(1360)) * g_scale;
    if (y < 54 * g_scale and x < width - 110 * g_scale) return w.HTCAPTION;
    return w.HTCLIENT;
}

fn wndproc(hwnd: w.HWND, msg: w.UINT, wp: w.WPARAM, lp: w.LPARAM) callconv(.c) w.LRESULT {
    switch (msg) {
        w.WM_PAINT => {
            var ps: w.PAINTSTRUCT = undefined;
            const hdc = w.BeginPaint(hwnd, &ps);
            defer _ = w.EndPaint(hwnd, &ps);
            if (g_app) |app| {
                if (g_paint) |*p| {
                    app.paint(p);
                    p.present(hdc);
                }
            }
            return 0;
        },
        w.WM_ERASEBKGND => return 1,
        w.WM_SIZE => {
            if (g_app) |app| {
                const cw: f32 = @floatFromInt(@as(u32, @intCast(lp & 0xFFFF)));
                const ch: f32 = @floatFromInt(@as(u32, @intCast((lp >> 16) & 0xFFFF)));
                app.width = cw / g_scale;
                app.height = ch / g_scale;
                if (g_paint) |*p| {
                    if (p.width != @as(u32, @intFromFloat(cw)) or p.height != @as(u32, @intFromFloat(ch))) {
                        p.destroy();
                        g_paint = gfx.Paint.create(app.gpa, @intFromFloat(cw), @intFromFloat(ch), g_scale) catch null;
                    }
                }
            }
            return 0;
        },
        w.WM_TIMER => {
            if (g_app) |app| {
                switch (wp) {
                    1 => {
                        app.tick();
                        _ = w.InvalidateRect(hwnd, null, 0);
                    },
                    2 => if (app.animating()) {
                        _ = w.InvalidateRect(hwnd, null, 0);
                    },
                    else => {},
                }
            }
            return 0;
        },
        w.WM_MOUSEMOVE => {
            if (g_app) |app| {
                const x: f32 = @as(f32, @floatFromInt(@as(i32, @intCast(lp & 0xFFFF)))) / g_scale;
                const y: f32 = @as(f32, @floatFromInt(@as(i32, @intCast((lp >> 16) & 0xFFFF)))) / g_scale;
                app.mouse_x = x;
                app.mouse_y = y;
                const hit = app.hitTest(x, y);
                const new_action: app_mod.Action = if (hit) |h| h.action else .none;
                const new_index: usize = if (hit) |h| h.index else 0;
                if (new_action != app.hover or new_index != app.hover_index) {
                    app.hover = new_action;
                    app.hover_index = new_index;
                    _ = w.InvalidateRect(hwnd, null, 0);
                }
            }
            return 0;
        },
        w.WM_LBUTTONDOWN => {
            if (g_app) |app| {
                const x: f32 = @as(f32, @floatFromInt(@as(i32, @intCast(lp & 0xFFFF)))) / g_scale;
                const y: f32 = @as(f32, @floatFromInt(@as(i32, @intCast((lp >> 16) & 0xFFFF)))) / g_scale;
                app.click(x, y);
                if (app.quit) _ = w.PostMessageW(hwnd, w.WM_CLOSE, 0, 0);
                _ = w.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },
        w.WM_CHAR => {
            if (g_app) |app| app.char(@intCast(wp & 0xFFFF));
            _ = w.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        w.WM_KEYDOWN => {
            if (g_app) |app| {
                switch (wp) {
                    w.VK_BACK => app.backspace(),
                    w.VK_RETURN => app.commit(),
                    w.VK_ESCAPE => {
                        app.editing = null;
                        app.settings_open = false;
                    },
                    w.VK_F5 => app.rescan(),
                    w.VK_F2 => app.settings_open = !app.settings_open,
                    else => {},
                }
                _ = w.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },
        w.WM_NCHITTEST => return nchittest(hwnd, lp),
        w.WM_DESTROY => {
            w.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return w.DefWindowProcW(hwnd, msg, wp, lp);
}

fn fillDemo(app: *app_mod.App) void {
    app.demo = true;
    app.snap = .{
        .ok = true,
        .healthy = true,
        .model = "Nemotron-3.5-Bolt",
        .version = "1.1.6",
        .backend = "cuda",
        .decode_tps = 88.7,
        .prefill_tps = 2463,
        .running = 4,
        .waiting = 0,
        .gen_running = 1840,
        .prompt_total = 1_284_311,
        .gen_total = 402_884,
        .drafted = 128_401,
        .accepted = 52_640,
        .rounds = 88_120,
        .mem_active = @as(u64, 34) << 30,
        .mem_cache = @as(u64, 4) << 30,
        .mem_peak = @as(u64, 41) << 30,
        .mem_limit = @as(u64, 96) << 30,
        .kv_ratio = 0.42,
        .http_total = 9_812,
    };
    const now = util.nowMs(app.io);
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        const phase: f64 = @as(f64, @floatFromInt(i)) / 300.0;
        const wave = 70.0 + 40.0 * @sin(phase * 9.0) + 18.0 * @sin(phase * 31.0);
        app.history.push(.{
            .t_ms = now - @as(i64, @intCast((300 - i) * 1000)),
            .decode = @max(0, wave),
            .prefill = if (i % 40 == 0) 2100 else 0,
            .mem = @as(u64, 34) << 30,
        });
    }
    app.anim_decode = 88.7;
    app.anim_prefill = 2463;
    app.setStatus("serving", theme.pal.green);
}

const WarmCtx = struct {
    client: *std.http.Client,
    port: u16,
    model: []const u8,

    fn run(ctx: *WarmCtx) void {
        const ok = stats.warmup(ctx.client, ctx.port, ctx.model, 512);
        std.debug.print("warmup ok={}\n", .{ok});
    }
};

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(a);
    var shot = false;
    var shot_path: []const u8 = "";
    var load_index: ?usize = null;
    var attach_port: ?u16 = null;
    var wait_s: u32 = 0;
    var skin: []const u8 = "";
    var open_settings = false;
    for (argv, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--shot")) {
            shot = true;
            if (i + 1 < argv.len) shot_path = argv[i + 1];
        } else if (std.mem.eql(u8, arg, "--load")) {
            if (i + 1 < argv.len) load_index = std.fmt.parseInt(usize, argv[i + 1], 10) catch null;
        } else if (std.mem.eql(u8, arg, "--attach")) {
            if (i + 1 < argv.len) attach_port = std.fmt.parseInt(u16, argv[i + 1], 10) catch null;
        } else if (std.mem.eql(u8, arg, "--wait")) {
            if (i + 1 < argv.len) wait_s = std.fmt.parseInt(u32, argv[i + 1], 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--skin")) {
            if (i + 1 < argv.len) skin = argv[i + 1];
        } else if (std.mem.eql(u8, arg, "--settings")) {
            open_settings = true;
        }
    }

    std.debug.print("argv:", .{});
    for (argv) |aa| std.debug.print(" [{s}]", .{aa});
    std.debug.print("\n", .{});
    _ = w.SetProcessDPIAware();
    var input: w.GdiplusStartupInput = .{};
    input.GdiplusVersion = 1;
    if (w.GdiplusStartup(&g_token, &input, null) != 0) return error.Gdiplus;

    const root = findRoot(a, io, init.environ_map);
    const exe = std.fmt.allocPrint(a, "{s}/tensorfold/zig-out/native/bin/tensorfold-native.exe", .{root}) catch "";
    var app = try app_mod.App.init(init.gpa, io, root, exe, init.environ_map);

    // before the headless --shot path, so skins apply to captures too
    if (skin.len > 0) {
        if (theme.indexOf(skin)) |si| app.setTheme(si) else std.debug.print("unknown skin '{s}'\n", .{skin});
    }
    if (open_settings) app.settings_open = true;

    if (load_index) |idx| {
        if (idx < app.cat.models.len) {
            app.selected = idx;
            app.loadSelected();
        }
    } else if (attach_port) |port| {
        _ = app.attach(port);
    }

    if (shot) {
        if (wait_s > 0) {
            var elapsed: u32 = 0;
            var warmed = false;
            var warm_start: u32 = 0;
            while (elapsed < wait_s * 4) : (elapsed += 1) {
                w.Sleep(250);
                app.tick();
                const target: ?u16 = if (app.server) |s| (if (s.state == .serving) s.port else null) else app.attached_port;
                if (target) |port| {
                    if (!warmed) {
                        warmed = true;
                        warm_start = elapsed;
                        const ctx = try init.gpa.create(WarmCtx);
                        const model_copy = init.arena.allocator().dupe(u8, app.snap.model) catch app.snap.model;
                        ctx.* = .{ .client = &app.client, .port = port, .model = model_copy };
                        _ = std.Thread.spawn(.{}, WarmCtx.run, .{ctx}) catch {};
                    } else if (elapsed - warm_start > 28) break;
                }
                if (app.server) |s| {
                    if (s.state == .failed) break;
                }
            }
            std.debug.print("after wait: server={s} ok={} decode={d:.1} model={s}\n", .{
                if (app.server) |s| @tagName(s.state) else "none",
                app.snap_ok,
                app.snap.decode_tps,
                app.snap.model,
            });
        }
        // a shot taken after the generation finished would show a zeroed gauge;
        // paint the last measured rates instead so the frame is representative
        if (wait_s > 0) {
            var i: usize = app.history.len;
            while (i > 0) {
                i -= 1;
                const smp = app.history.at(i);
                if (smp.decode > 0.5) {
                    app.anim_decode = smp.decode;
                    app.anim_prefill = smp.prefill;
                    app.snap.decode_tps = smp.decode;
                    if (app.snap.running == 0) app.snap.running = 1;
                    break;
                }
            }
        }
        if (!app.demo and wait_s == 0) fillDemo(&app);
        std.debug.print("root={s} models={d}\n", .{ root, app.cat.models.len });
        for (app.cat.models) |mm| std.debug.print("  {s} {s} {d} bytes\n", .{ mm.name, mm.family, mm.bytes });
        for (app.cat.warnings) |wn| std.debug.print("  warn: {s}\n", .{wn});
        const scale: f32 = 2.0;
        var p = try gfx.Paint.create(init.gpa, @intFromFloat(1360 * scale), @intFromFloat(860 * scale), scale);
        app.paint(&p);
        try p.saveBmp(io, if (shot_path.len > 0) shot_path else "shot.bmp");
        p.destroy();
        app.deinit();
        w.GdiplusShutdown(g_token);
        return;
    }

    if (load_index == null and attach_port == null) app.autoAttach();

    g_app = &app;
    g_scale = @as(f32, @floatFromInt(w.GetDpiForSystem())) / 96.0;
    const cls = wstr("TensorFoldGui");
    var wc: w.WNDCLASSEXW = .{};
    wc.cbSize = @sizeOf(w.WNDCLASSEXW);
    wc.style = w.CS_HREDRAW | w.CS_VREDRAW;
    wc.lpfnWndProc = wndproc;
    const hinst = w.GetModuleHandleW(null);
    // the mark embedded from assets/tensorfold.rc, id 1
    const icon_big: w.HANDLE = w.LoadImageW(hinst, @ptrFromInt(100), @intCast(w.IMAGE_ICON), 0, 0, @intCast(w.LR_DEFAULTSIZE));
    const icon_small: w.HANDLE = w.LoadImageW(hinst, @ptrFromInt(100), @intCast(w.IMAGE_ICON), 16, 16, 0);
    wc.hInstance = hinst;
    wc.hCursor = w.LoadCursorW(null, @ptrFromInt(32512));
    wc.hIcon = @ptrCast(@alignCast(icon_big));
    wc.hIconSm = @ptrCast(@alignCast(icon_small));
    wc.lpszClassName = &cls;
    _ = w.RegisterClassExW(&wc);

    const px_w: i32 = @intFromFloat(1360 * g_scale);
    const px_h: i32 = @intFromFloat(860 * g_scale);
    const title = wstr("TensorFold");
    const hwnd = w.CreateWindowExW(w.WS_EX_APPWINDOW, &cls, &title, w.WS_POPUP, 120, 80, px_w, px_h, null, null, w.GetModuleHandleW(null), null);
    app.hwnd = hwnd;
    // class icon covers the taskbar; WM_SETICON also covers windows that ask later
    _ = w.SendMessageW(hwnd, @intCast(w.WM_SETICON), @intCast(w.ICON_BIG), @intCast(@intFromPtr(icon_big)));
    _ = w.SendMessageW(hwnd, @intCast(w.WM_SETICON), @intCast(w.ICON_SMALL), @intCast(@intFromPtr(icon_small)));
    g_paint = try gfx.Paint.create(init.gpa, @intCast(px_w), @intCast(px_h), g_scale);

    var margins = w.MARGINS{ .cxLeftWidth = 1, .cxRightWidth = 1, .cyTopHeight = 1, .cyBottomHeight = 1 };
    _ = w.DwmExtendFrameIntoClientArea(hwnd, &margins);
    var corner: i32 = 2; // DWMWCP_ROUND
    _ = w.DwmSetWindowAttribute(hwnd, 33, &corner, @sizeOf(i32));

    _ = w.ShowWindow(hwnd, w.SW_SHOW);
    _ = w.AllowSetForegroundWindow(w.ASFW_ANY);
    // a process launched from a background shell cannot take the foreground
    // unless it shares input state with the current foreground thread
    if (w.GetForegroundWindow()) |fg| {
        const fg_thread = w.GetWindowThreadProcessId(fg, null);
        const my_thread = w.GetCurrentThreadId();
        if (fg_thread != 0 and fg_thread != my_thread) {
            _ = w.AttachThreadInput(my_thread, fg_thread, 1);
            _ = w.SetForegroundWindow(hwnd);
            _ = w.SetFocus(hwnd);
            _ = w.AttachThreadInput(my_thread, fg_thread, 0);
        } else {
            _ = w.SetForegroundWindow(hwnd);
        }
    } else _ = w.SetForegroundWindow(hwnd);
    _ = w.BringWindowToTop(hwnd);
    _ = w.UpdateWindow(hwnd);
    _ = w.SetTimer(hwnd, 1, 1000, null);
    _ = w.SetTimer(hwnd, 2, 40, null);

    var msg: w.MSG = undefined;
    while (w.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }
    app.deinit();
    w.GdiplusShutdown(g_token);
}
