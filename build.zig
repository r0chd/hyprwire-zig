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
        .root_source_file = b.path("src/helpers/root.zig"),
        .target = target,
    });

    return mod;
}

pub fn buildExamples(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, hyprwire: *std.Build.Module) void {
    // var scanner = Scanner.init(b, .{});
    // scanner.addCustomProtocol(b.path("./examples/simple/protocol-v1.xml"));
    // scanner.generate("my_manager_v1", 1);

    // Build simple-client
    const simple_client = b.addExecutable(.{
        .name = "simple-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/simple/client.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hyprwire", .module = hyprwire },
            },
        }),
    });
    simple_client.root_module.link_libc = true;
    b.installArtifact(simple_client);

    // Build simple-server
    const simple_server = b.addExecutable(.{
        .name = "simple-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/simple/server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hyprwire", .module = hyprwire },
            },
        }),
    });
    simple_server.root_module.link_libc = true;
    b.installArtifact(simple_server);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_options = b.addOptions();
    exe_options.addOption([:0]const u8, "version", zon.version);
    exe_options.addOption(u32, "protocol_version", 1);
    exe_options.addOption(bool, "trace", true);

    const xml = b.dependency("xml", .{
        .target = target,
        .optimize = optimize,
    });

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

    buildExamples(b, target, optimize, hyprwire);

    const examples_step = b.step("examples", "Build all examples");
    examples_step.dependOn(b.getInstallStep());

    const scanner = b.addExecutable(.{
        .name = "hyprwire_scanner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scanner/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });

    scanner.root_module.addImport("xml", xml.module("xml"));
    scanner.root_module.addImport("hyprwire", hyprwire);

    b.installArtifact(scanner);

    const run_step = b.step("scanner", "Run the scanner");
    const run_cmd = b.addRunArtifact(scanner);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
