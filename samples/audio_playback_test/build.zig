const builtin = @import("builtin");
const std = @import("std");

const Options = @import("../../build.zig").Options;
const content_dir = "audio_playback_test_content/";

pub fn build(b: *std.Build, options: Options) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "audio_playback_test",
        .root_source_file = .{ .path = thisDir() ++ "/src/audio_playback_test.zig" },
        .target = options.target,
        .optimize = options.optimize,
    });

    @import("system_sdk").addLibraryPathsTo(exe);

    const zwin32 = b.dependency("zwin32", .{
        .target = options.target,
    });
    const zwin32_module = zwin32.module("root");
    exe.root_module.addImport("zwin32", zwin32_module);

    const zd3d12 = b.dependency("zd3d12", .{
        .target = options.target,
        .debug_layer = options.zd3d12_enable_debug_layer,
        .gbv = options.zd3d12_enable_gbv,
    });
    const zd3d12_module = zd3d12.module("root");
    exe.root_module.addImport("zd3d12", zd3d12_module);

    @import("../common/build.zig").link(exe, .{
        .zwin32 = zwin32_module,
        .zd3d12 = zd3d12_module,
    });

    const exe_options = b.addOptions();
    exe.root_module.addOptions("build_options", exe_options);
    exe_options.addOption([]const u8, "content_dir", content_dir);

    const install_content_step = b.addInstallDirectory(.{
        .source_dir = .{ .path = thisDir() ++ "/" ++ content_dir },
        .install_dir = .{ .custom = "" },
        .install_subdir = "bin/" ++ content_dir,
    });
    if (builtin.os.tag == .windows or builtin.os.tag == .linux) {
        const dxc_step = buildShaders(b);
        exe.step.dependOn(dxc_step);
        install_content_step.step.dependOn(dxc_step);
    }
    exe.step.dependOn(&install_content_step.step);

    // This is needed to export symbols from an .exe file.
    // We export D3D12SDKVersion and D3D12SDKPath symbols which
    // is required by DirectX 12 Agility SDK.
    exe.rdynamic = true;

    @import("zwin32").install_xaudio2(&exe.step, .bin, "libs/zwin32") catch unreachable;
    @import("zwin32").install_d3d12(&exe.step, .bin, "libs/zwin32") catch unreachable;

    return exe;
}

fn buildShaders(b: *std.Build) *std.Build.Step {
    const dxc_step = b.step("audio_playback_test-dxc", "Build shaders for 'audio playback test' demo");

    makeDxcCmd(
        b,
        dxc_step,
        "../common/src/hlsl/common.hlsl",
        "vsImGui",
        "imgui.vs.cso",
        "vs",
        "PSO__IMGUI",
    );
    makeDxcCmd(
        b,
        dxc_step,
        "../common/src/hlsl/common.hlsl",
        "psImGui",
        "imgui.ps.cso",
        "ps",
        "PSO__IMGUI",
    );
    makeDxcCmd(
        b,
        dxc_step,
        "src/audio_playback_test.hlsl",
        "vsLines",
        "lines.vs.cso",
        "vs",
        "PSO__LINES",
    );
    makeDxcCmd(
        b,
        dxc_step,
        "src/audio_playback_test.hlsl",
        "psLines",
        "lines.ps.cso",
        "ps",
        "PSO__LINES",
    );
    makeDxcCmd(
        b,
        dxc_step,
        "src/audio_playback_test.hlsl",
        "vsImage",
        "image.vs.cso",
        "vs",
        "PSO__IMAGE",
    );
    makeDxcCmd(
        b,
        dxc_step,
        "src/audio_playback_test.hlsl",
        "psImage",
        "image.ps.cso",
        "ps",
        "PSO__IMAGE",
    );

    return dxc_step;
}

fn makeDxcCmd(
    b: *std.Build,
    dxc_step: *std.Build.Step,
    comptime input_path: []const u8,
    comptime entry_point: []const u8,
    comptime output_filename: []const u8,
    comptime profile: []const u8,
    comptime define: []const u8,
) void {
    const shader_ver = "6_6";
    const shader_dir = thisDir() ++ "/" ++ content_dir ++ "shaders/";

    const dxc_path = switch (builtin.target.os.tag) {
        .windows => thisDir() ++ "/../../libs/zwin32/bin/x64/dxc.exe",
        .linux => thisDir() ++ "/../../libs/zwin32/bin/x64/dxc",
        else => @panic("Unsupported target"),
    };

    const dxc_command = [9][]const u8{
        dxc_path,
        thisDir() ++ "/" ++ input_path,
        "/E " ++ entry_point,
        "/Fo " ++ shader_dir ++ output_filename,
        "/T " ++ profile ++ "_" ++ shader_ver,
        if (define.len == 0) "" else "/D " ++ define,
        "/WX",
        "/Ges",
        "/O3",
    };

    const cmd_step = b.addSystemCommand(&dxc_command);
    if (builtin.target.os.tag == .linux) {
        cmd_step.setEnvironmentVariable("LD_LIBRARY_PATH", thisDir() ++ "/../../libs/zwin32/bin/x64");
    }
    dxc_step.dependOn(&cmd_step.step);
}

inline fn thisDir() []const u8 {
    return comptime std.fs.path.dirname(@src().file) orelse ".";
}
