const std = @import("std");
const zon = @import("./build.zig.zon");

pub fn buildHyprwire(b: *std.Build, target: std.Build.ResolvedTarget, helpers: *std.Build.Module) *std.Build.Module {
    const mod = b.addModule("hyprwire", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
    });
    mod.addImport("helpers", helpers);

    return mod;
}

pub fn buildHelpers(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Module {
    const mod = b.addModule("helpers", .{
        .root_source_file = b.path("src/helpers.zig"),
        .target = target,
    });

    return mod;
}

pub fn buildServer(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, hyprwire: *std.Build.Module) void {
    const exe = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hyprwire", .module = hyprwire },
            },
        }),
    });
    exe.root_module.link_libc = true;
    b.installArtifact(exe);

    const run = b.step("server", "Run the server binary");
    const run_cmd = b.addRunArtifact(exe);
    run.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}

pub fn buildClient(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, hyprwire: *std.Build.Module) void {
    const exe = b.addExecutable(.{
        .name = "client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/client.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hyprwire", .module = hyprwire },
            },
        }),
    });
    exe.root_module.link_libc = true;
    b.installArtifact(exe);

    const run = b.step("client", "Run the client binary");
    const run_cmd = b.addRunArtifact(exe);
    run.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xml = b.dependency("xml", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_options = b.addOptions();
    exe_options.addOption([:0]const u8, "version", zon.version);
    exe_options.addOption(u32, "protocol_version", 1);
    exe_options.addOption(bool, "trace", true);

    const helpers = buildHelpers(b, target);
    const hyprwire = buildHyprwire(b, target, helpers);
    hyprwire.addOptions("build_options", exe_options);
    hyprwire.addImport("xml", xml.module("xml"));

    const mod_tests = b.addTest(.{
        .root_module = hyprwire,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    buildServer(b, target, optimize, hyprwire);
    buildClient(b, target, optimize, hyprwire);
}
