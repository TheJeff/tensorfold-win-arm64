const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const exe = b.addExecutable(.{
        .name = "tensorfold-gui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.subsystem = .windows;
    // assets/tensorfold.rc embeds the mark as RT_GROUP_ICON id 1 (window + taskbar + Explorer)
    exe.root_module.addWin32ResourceFile(.{ .file = b.path("assets/tensorfold.rc") });
    for ([_][]const u8{ "gdiplus", "user32", "gdi32", "kernel32", "dwmapi", "ole32", "iphlpapi" }) |lib| {
        exe.root_module.linkSystemLibrary(lib, .{});
    }
    b.installArtifact(exe);
}
