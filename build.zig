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
    mod.addImport("xml", xml.module("xml"));

    const scanner_mod = b.addModule("scanner", .{
        .root_source_file = b.path("scanner/root.zig"),
        .target = target,
    });
    scanner_mod.addImport("xml", xml.module("xml"));
    scanner_mod.addImport("hyprwire", mod);

    mod.addImport("scanner", scanner_mod);

    const exe_options = b.addOptions();

    exe_options.addOption([]const u8, "version", "0.2.1");

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
        .root_module = mod,
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
                .{ .name = "hyprwire", .module = mod },
            },
        }),
    });
    scanner_snapshot_test.root_module.addImport("xml", xml.module("xml"));
    const run_scanner_snapshot_test = b.addRunArtifact(scanner_snapshot_test);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_scanner_snapshot_test.step);

    const client_exe = b.addExecutable(.{
        .name = "client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/client.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hyprwire", .module = mod },
            },
        }),
    });
    client_exe.root_module.link_libc = true;
    b.installArtifact(client_exe);

    const server_exe = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "hyprwire", .module = mod },
            },
        }),
    });
    server_exe.root_module.link_libc = true;
    b.installArtifact(server_exe);

    const run_client = b.step("client", "Run the client binary");
    const run_client_cmd = b.addRunArtifact(client_exe);
    run_client.dependOn(&run_client_cmd.step);
    run_client_cmd.step.dependOn(b.getInstallStep());

    const run_server = b.step("server", "Run the server binary");
    const run_server_cmd = b.addRunArtifact(server_exe);
    run_server.dependOn(&run_server_cmd.step);
    run_server_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_client_cmd.addArgs(args);
        run_server_cmd.addArgs(args);
    }
}
