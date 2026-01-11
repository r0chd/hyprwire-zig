const std = @import("std");

const VERSION: [:0]const u8 = "0.2.1";

pub fn buildHyprwire(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Module {
    const mod = b.addModule("hyprwire", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
    });

    return mod;
}

pub fn buildScanner(b: *std.Build, target: std.Build.ResolvedTarget, xml: *std.Build.Dependency, hw: *std.Build.Module) *std.Build.Module {
    const scanner = b.addModule("scanner", .{
        .root_source_file = b.path("scanner/root.zig"),
        .target = target,
    });
    scanner.addImport("xml", xml.module("xml"));
    scanner.addImport("hyprwire", hw);

    return scanner;
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

    const hyprwire = buildHyprwire(b, target);
    const scanner_mod = buildScanner(b, target, xml, hyprwire);

    hyprwire.addImport("scanner", scanner_mod);

    const exe_options = b.addOptions();

    exe_options.addOption([:0]const u8, "version", VERSION);

    const scanner = b.addExecutable(.{
        .name = "hyprwire_scanner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scanner/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "scanner", .module = scanner_mod },
            },
        }),
    });

    scanner.root_module.addImport("xml", xml.module("xml"));
    scanner.root_module.addOptions("build_options", exe_options);

    b.installArtifact(scanner);

    const run_step = b.step("scanner", "Run the scanner");
    const run_cmd = b.addRunArtifact(scanner);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = hyprwire,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = scanner.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const scanner_snapshot_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("scanner/tests/snapshot_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hyprwire", .module = hyprwire },
            },
        }),
    });
    scanner_snapshot_test.root_module.addImport("xml", xml.module("xml"));
    const run_scanner_snapshot_test = b.addRunArtifact(scanner_snapshot_test);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_scanner_snapshot_test.step);

    buildServer(b, target, optimize, hyprwire);
    buildClient(b, target, optimize, hyprwire);
}
