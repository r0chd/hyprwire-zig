const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const xml = b.dependency("xml", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("hyprwire", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
    });

    const exe_options = b.addOptions();

    exe_options.addOption([]const u8, "version", "0.2.1");

    const scanner = b.addExecutable(.{
        .name = "hyprwire_scanner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scanner/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hyprwire", .module = mod },
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
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = scanner.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
