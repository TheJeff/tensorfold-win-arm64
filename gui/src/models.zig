//! Model inventory: scans the repo's models folder, reads checkpoint metadata,
//! and merges per-model launch profiles from gui/models.json.
const std = @import("std");
const util = @import("util.zig");

pub const EnvVar = struct { key: []const u8, value: []const u8 };

pub const Profile = struct {
    port: u16 = 8082,
    parallel: u32 = 4,
    context: u32 = 131072,
    cache_gib: u32 = 4,
    env: []const EnvVar = &.{},
    extra_args: []const []const u8 = &.{},
};

pub const Model = struct {
    dir: []const u8,
    name: []const u8,
    family: []const u8,
    quant: []const u8,
    bytes: u64 = 0,
    shards: u32 = 0,
    drafter: []const u8 = "",
    profile: Profile = .{},
};

pub const Catalog = struct {
    exe: []const u8,
    root: []const u8,
    models: []Model,
    warnings: []const []const u8,
};

pub const config_rel = "gui/models.json";

fn readJson(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) ?std.json.Value {
    const text = dir.readFileAlloc(io, name, a, .limited(64 << 20)) catch return null;
    return std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch null;
}

fn strOf(v: ?std.json.Value) []const u8 {
    const val = v orelse return "";
    return switch (val) {
        .string => |s| s,
        else => "",
    };
}

fn objGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

/// Directory name -> display name: "Nemotron-3.5-Bolt-74B-A9B-24GB" -> "Nemotron 3.5 Bolt 74B A9B 24GB"
fn prettyName(a: std.mem.Allocator, dir_name: []const u8) []const u8 {
    var out = a.alloc(u8, dir_name.len) catch return dir_name;
    for (dir_name, 0..) |ch, i| out[i] = if (ch == '-' or ch == '_') ' ' else ch;
    return out;
}

fn lowerContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |c, j| {
            const h = std.ascii.toLower(haystack[i + j]);
            if (h != c) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn scanDir(a: std.mem.Allocator, io: std.Io, root: []const u8, dir_name: []const u8) ?struct {
    bytes: u64,
    shards: u32,
    family: []const u8,
    quant: []const u8,
    is_drafter: bool,
} {
    var path_buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/models/{s}", .{ root, dir_name }) catch return null;
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var bytes: u64 = 0;
    var shards: u32 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .directory) {
            // some exports keep the shards in a tensors/ subfolder
            var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
            defer sub.close(io);
            var sit = sub.iterate();
            while (sit.next(io) catch null) |se| {
                if (se.kind == .directory) continue;
                if (std.mem.endsWith(u8, se.name, ".safetensors")) shards += 1;
                const st = sub.statFile(io, se.name, .{}) catch continue;
                bytes += st.size;
            }
            continue;
        }
        if (std.mem.endsWith(u8, entry.name, ".safetensors")) shards += 1;
        const st = dir.statFile(io, entry.name, .{}) catch continue;
        bytes += st.size;
    }

    const cfg = readJson(a, io, dir, "config.json") orelse return null;
    var family: []const u8 = "";
    if (objGet(cfg, "llm_config")) |llm| family = strOf(objGet(llm, "model_type"));
    if (family.len == 0) family = strOf(objGet(cfg, "model_type"));
    if (family.len == 0) {
        if (objGet(cfg, "architectures")) |arch| switch (arch) {
            .array => |arr| if (arr.items.len > 0) {
                family = strOf(arr.items[0]);
            },
            else => {},
        };
    }
    var quant: []const u8 = strOf(objGet(cfg, "dtype"));
    if (readJson(a, io, dir, "hf_quant_config.json")) |qc| {
        if (objGet(qc, "quantization")) |q| {
            const algo = strOf(objGet(q, "quant_algo"));
            if (algo.len > 0) quant = algo;
        }
    }
    // drafters are named for it; a checkpoint still downloading must not be
    // mistaken for one just because it has few shards yet
    const is_drafter = lowerContains(dir_name, "lil") or lowerContains(dir_name, "draft") or lowerContains(dir_name, "corr");
    return .{ .bytes = bytes, .shards = shards, .family = family, .quant = quant, .is_drafter = is_drafter };
}

fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    var i: usize = 0;
    while (i < a.len and i < b.len and a[i] == b[i]) : (i += 1) {}
    return i;
}

/// Reads gui/models.json profiles into the scanned catalog. Missing entries keep defaults.
fn applyConfig(a: std.mem.Allocator, io: std.Io, root: []const u8, models: []Model) void {
    var dir = std.Io.Dir.openDirAbsolute(io, root, .{}) catch return;
    defer dir.close(io);
    const cfg = readJson(a, io, dir, config_rel) orelse return;
    const list = objGet(cfg, "models") orelse return;
    switch (list) {
        .array => |arr| {
            for (arr.items) |item| {
                const dir_name = strOf(objGet(item, "dir"));
                for (models) |*m| {
                    if (!std.mem.endsWith(u8, m.dir, dir_name)) continue;
                    if (objGet(item, "port")) |v| if (v == .integer) {
                        m.profile.port = @intCast(@max(1, @min(65535, v.integer)));
                    };
                    if (objGet(item, "parallel")) |v| if (v == .integer) {
                        m.profile.parallel = @intCast(@max(1, @min(512, v.integer)));
                    };
                    if (objGet(item, "context")) |v| if (v == .integer) {
                        m.profile.context = @intCast(@max(512, @min(1 << 21, v.integer)));
                    };
                    if (objGet(item, "cache_gib")) |v| if (v == .integer) {
                        m.profile.cache_gib = @intCast(@max(0, @min(256, v.integer)));
                    };
                    if (objGet(item, "drafter")) |v| if (v == .string) {
                        m.drafter = v.string;
                    };
                    if (objGet(item, "env")) |env| switch (env) {
                        .object => |o| {
                            var list2 = a.alloc(EnvVar, o.count()) catch continue;
                            var idx: usize = 0;
                            var eit = o.iterator();
                            while (eit.next()) |e| {
                                list2[idx] = .{ .key = e.key_ptr.*, .value = strOf(e.value_ptr.*) };
                                idx += 1;
                            }
                            m.profile.env = list2[0..idx];
                        },
                        else => {},
                    };
                    if (objGet(item, "extra_args")) |extra| switch (extra) {
                        .array => |arr2| {
                            var list3 = a.alloc([]const u8, arr2.items.len) catch continue;
                            for (arr2.items, 0..) |v, i| list3[i] = strOf(v);
                            m.profile.extra_args = list3;
                        },
                        else => {},
                    };
                }
            }
        },
        else => {},
    }
}

pub fn save(a: std.mem.Allocator, io: std.Io, cat: Catalog) void {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    w.print("{{\n  \"exe\": \"{s}\",\n  \"models\": [\n", .{cat.exe}) catch return;
    for (cat.models, 0..) |m, i| {
        w.print("    {{\n      \"dir\": \"{s}\",\n      \"port\": {d},\n      \"parallel\": {d},\n      \"context\": {d},\n      \"cache_gib\": {d},\n", .{ m.dir, m.profile.port, m.profile.parallel, m.profile.context, m.profile.cache_gib }) catch return;
        if (m.drafter.len > 0) w.print("      \"drafter\": \"{s}\",\n", .{m.drafter}) catch return;
        w.print("      \"env\": {{", .{}) catch return;
        for (m.profile.env, 0..) |e, j| {
            w.print("{s}\"{s}\": \"{s}\"", .{ if (j == 0) "" else ", ", e.key, e.value }) catch return;
        }
        w.print("}},\n      \"extra_args\": [", .{}) catch return;
        for (m.profile.extra_args, 0..) |x, j| {
            w.print("{s}\"{s}\"", .{ if (j == 0) "" else ", ", x }) catch return;
        }
        w.print("]\n    }}{s}\n", .{if (i + 1 < cat.models.len) "," else ""}) catch return;
    }
    w.print("  ]\n}}\n", .{}) catch return;
    var dir = std.Io.Dir.openDirAbsolute(io, cat.root, .{}) catch return;
    defer dir.close(io);
    dir.writeFile(io, .{ .sub_path = config_rel, .data = out.written() }) catch {};
}
fn writeDefaults(a: std.mem.Allocator, io: std.Io, root: []const u8, exe: []const u8, models: []Model) void {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    w.print("{{\n  \"exe\": \"{s}\",\n  \"models\": [\n", .{exe}) catch return;
    for (models, 0..) |m, i| {
        w.print("    {{\n      \"dir\": \"{s}\",\n      \"port\": {d},\n      \"parallel\": {d},\n      \"context\": {d},\n      \"cache_gib\": {d},\n", .{ m.dir, m.profile.port, m.profile.parallel, m.profile.context, m.profile.cache_gib }) catch return;
        if (m.drafter.len > 0) w.print("      \"drafter\": \"{s}\",\n", .{m.drafter}) catch return;
        w.print("      \"env\": {{", .{}) catch return;
        for (m.profile.env, 0..) |e, j| {
            w.print("{s}\"{s}\": \"{s}\"", .{ if (j == 0) "" else ", ", e.key, e.value }) catch return;
        }
        w.print("}},\n      \"extra_args\": []\n    }}{s}\n", .{if (i + 1 < models.len) "," else ""}) catch return;
    }
    w.print("  ]\n}}\n", .{}) catch return;
    var dir = std.Io.Dir.openDirAbsolute(io, root, .{}) catch return;
    defer dir.close(io);
    dir.writeFile(io, .{ .sub_path = config_rel, .data = out.written() }) catch {};
}

pub fn load(io: std.Io, a: std.mem.Allocator, root: []const u8, exe: []const u8) Catalog {
    var warnings: std.ArrayList([]const u8) = .empty;
    var models: std.ArrayList(Model) = .empty;
    var drafters: std.ArrayList(struct { name: []const u8, dir: []const u8 }) = .empty;

    var path_buf: [1024]u8 = undefined;
    const models_path = std.fmt.bufPrint(&path_buf, "{s}/models", .{root}) catch "";
    if (std.Io.Dir.openDirAbsolute(io, models_path, .{ .iterate = true })) |dir_const| {
        var dir = dir_const;
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            const name = a.dupe(u8, entry.name) catch continue;
            const meta = scanDir(a, io, root, name) orelse {
                warnings.append(a, name) catch {};
                continue;
            };
            var dpath_buf: [1024]u8 = undefined;
            const dpath = std.fmt.bufPrint(&dpath_buf, "{s}/models/{s}", .{ root, name }) catch continue;
            if (meta.is_drafter) {
                drafters.append(a, .{ .name = name, .dir = a.dupe(u8, dpath) catch continue }) catch {};
                continue;
            }
            models.append(a, .{
                .dir = a.dupe(u8, dpath) catch continue,
                .name = prettyName(a, name),
                .family = meta.family,
                .quant = meta.quant,
                .bytes = meta.bytes,
                .shards = meta.shards,
                .drafter = "",
                .profile = .{},
            }) catch {};
        }
        dir.close(io);
    } else |_| {
        warnings.append(a, "models/ folder not found") catch {};
    }

    // pair drafters with the model they extend (longest shared name prefix)
    for (models.items) |*m| {
        var best: ?usize = null;
        var best_len: usize = 0;
        const base = util.basename(m.dir);
        for (drafters.items, 0..) |d, i| {
            const n = commonPrefixLen(base, d.name);
            if (n > best_len and n >= 10) {
                best_len = n;
                best = i;
            }
        }
        if (best) |i| m.drafter = drafters.items[i].dir;
    }

    // defaults before the config overlay: unique ports, Bolt recipe env
    for (models.items, 0..) |*m, i| {
        m.profile.port = @intCast(8082 + i);
        if (lowerContains(util.basename(m.dir), "bolt")) {
            m.profile.parallel = 4;
            m.profile.context = 131072;
            m.profile.cache_gib = 4;
            if (a.alloc(EnvVar, 7)) |env| {
                env[0] = .{ .key = "BOLT_KV", .value = "bf16" };
                env[1] = .{ .key = "BOLT_KV_PIN", .value = "0" };
                env[2] = .{ .key = "BOLT_SSM_LAZY", .value = "1" };
                env[3] = .{ .key = "BOLT_DRAFT_Q8", .value = "1" };
                env[4] = .{ .key = "BOLT_NV4_FP4", .value = "1" };
                env[5] = .{ .key = "TENSORFOLD_NO_UPDATE_CHECK", .value = "1" };
                env[6] = .{ .key = "BOLT_DRAFT", .value = m.drafter };
                m.profile.env = env;
            } else |_| {}
        } else if (std.mem.eql(u8, m.family, "qwen4_exp")) {
            // Qwen3.8 Flash Next on one 96 GiB framebuffer: the CUDA family keeps
            // bf16 caches (fp8 is refused), so two full windows fit, not five
            m.profile.parallel = 2;
            m.profile.context = 262144;
            m.profile.cache_gib = 4;
            if (a.alloc(EnvVar, 4)) |env| {
                env[0] = .{ .key = "TF_FLASHNEXT_DRAFTS", .value = "6" };
                env[1] = .{ .key = "TF_FLASHNEXT_GATHER_READ", .value = "pread" };
                env[2] = .{ .key = "TENSORFOLD_MEMORY_RESERVE_GIB", .value = "4" };
                env[3] = .{ .key = "TENSORFOLD_NO_UPDATE_CHECK", .value = "1" };
                m.profile.env = env;
            } else |_| {}
        }
    }

    applyConfig(a, io, root, models.items);

    const cfg_exists = blk: {
        var d = std.Io.Dir.openDirAbsolute(io, root, .{}) catch break :blk false;
        defer d.close(io);
        _ = d.statFile(io, config_rel, .{}) catch break :blk false;
        break :blk true;
    };
    if (!cfg_exists) writeDefaults(a, io, root, exe, models.items);

    return .{
        .exe = exe,
        .root = root,
        .models = models.items,
        .warnings = warnings.items,
    };
}
