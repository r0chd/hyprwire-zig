const std = @import("std");
const Build = std.Build;

const zon = @import("./build.zig.zon");

fn createModule(
    b: *Build,
    name: []const u8,
    root_source_file: Build.LazyPath,
    target: Build.ResolvedTarget,
    imports: ?[]const Build.Module.Import,
    link_ffi: bool,
) *Build.Module {
    const mod = b.addModule(name, .{
        .root_source_file = root_source_file,
        .target = target,
        .link_libc = link_ffi,
    });

    if (link_ffi) {
        mod.linkSystemLibrary("ffi", .{});
    }

    if (imports) |imps| {
        for (imps) |imp| {
            mod.addImport(imp.name, imp.module);
        }
    }

    return mod;
}

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_options = b.addOptions();
    exe_options.addOption([:0]const u8, "version", zon.version);
    exe_options.addOption(u32, "protocol_version", 1);

    const trait_dep = b.dependency("trait", .{
        .target = target,
        .optimize = optimize,
    });

    const helpers = b.addModule("helpers", .{
        .root_source_file = b.path("src/helpers/root.zig"),
        .target = target,
    });

    const protocols = b.createModule(.{
        .root_source_file = b.addWriteFiles().add("protocols.zig", ""),
        .target = target,
        .optimize = optimize,
    });

    const hyprwire = b.addModule("hyprwire", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
    });

    const xml = b.dependency("xml", .{
        .target = b.graph.host,
    });

    hyprwire.addImport("xml", xml.module("xml"));
    hyprwire.linkSystemLibrary("ffi", .{});
    hyprwire.addImport("helpers", helpers);
    hyprwire.addImport("trait", trait_dep.module("trait"));
    hyprwire.addImport("protocols", protocols);
    hyprwire.addOptions("build_options", exe_options);

    helpers.addImport("hyprwire", hyprwire);

    const mod_tests = b.addTest(.{
        .root_module = hyprwire,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    buildScannerSnapshotTests(b, test_step);

    buildExamples(b, target, optimize, hyprwire);
}

fn buildScannerSnapshotTests(b: *Build, test_step: *Build.Step) void {
    const scanner_exe = b.addExecutable(.{
        .name = "hyprwire-scanner-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scanner/main.zig"),
            .target = b.graph.host,
        }),
    });

    const xml_dep = b.dependency("xml", .{
        .target = b.graph.host,
    });
    scanner_exe.root_module.addImport("xml", xml_dep.module("xml"));

    const test_input = b.path("scanner/tests/protocol-v1.xml");

    const scanner_output_path = "/tmp/scanner-test-output";

    const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", scanner_output_path });

    const run_scanner = b.addRunArtifact(scanner_exe);
    run_scanner.addArg("-i");
    run_scanner.addFileArg(test_input);
    run_scanner.addArg("-o");
    run_scanner.addArg(scanner_output_path);
    run_scanner.step.dependOn(&mkdir.step);

    const snapshot_files = [_][]const u8{
        "test_protocol_v1-client.zig",
        "test_protocol_v1-server.zig",
        "test_protocol_v1-spec.zig",
    };

    for (snapshot_files) |filename| {
        const generated_file = b.fmt("{s}/{s}", .{ scanner_output_path, filename });
        const snapshot_file = b.path(b.fmt("scanner/tests/snapshots/{s}", .{filename}));

        const compare = b.addSystemCommand(&.{
            "diff",
            "-u",
            "--color=always",
            snapshot_file.getPath(b),
            generated_file,
        });

        compare.step.dependOn(&run_scanner.step);
        test_step.dependOn(&compare.step);
    }
}

fn buildExamples(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, hyprwire: *Build.Module) void {
    const scanner = Scanner.init(b, hyprwire);
    scanner.addCustomProtocol(b.path("./examples/simple/protocol-v1.xml"));
    scanner.generate("test_protocol_v1", 1);

    const client = b.addExecutable(.{
        .name = "simple-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/simple/client.zig"),
            .imports = &.{.{ .name = "hyprwire", .module = hyprwire }},
            .target = target,
            .optimize = optimize,
        }),
    });
    client.step.dependOn(&scanner.run.step);
    b.installArtifact(client);

    const server = b.addExecutable(.{
        .name = "simple-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/simple/server.zig"),
            .imports = &.{.{ .name = "hyprwire", .module = hyprwire }},
            .target = target,
            .optimize = optimize,
        }),
    });
    server.step.dependOn(&scanner.run.step);
    b.installArtifact(server);

    const examples_step = b.step("examples", "Build all examples");
    examples_step.dependOn(b.getInstallStep());
}

const hyprwire_build_zig = @This();

pub const Scanner = struct {
    run: *Build.Step.Run,
    output_dir: Build.LazyPath,
    b: *Build,
    write_files: *Build.Step.WriteFile,
    hyprwire: *Build.Module,

    const Self = @This();

    pub fn init(b: *Build, hyprwire: *Build.Module) *Self {
        const exe = b.addExecutable(.{
            .name = "hyprwire-scanner",
            .root_module = b.createModule(.{
                .root_source_file = hyprwire.owner.path("scanner/main.zig"),
                .target = b.graph.host,
            }),
        });

        const xml = hyprwire.import_table.get("xml").?;
        exe.root_module.addImport("xml", xml);

        const run = b.addRunArtifact(exe);
        run.addArg("-o");
        const output_dir = run.addOutputFileArg(".");

        const write_files = b.addWriteFiles();
        write_files.step.dependOn(&run.step);

        const scanner = b.allocator.create(Scanner) catch @panic("OOM");
        scanner.* = .{
            .run = run,
            .output_dir = output_dir,
            .b = b,
            .write_files = write_files,
            .hyprwire = hyprwire,
        };

        const protocols = hyprwire.import_table.get("protocols").?;
        protocols.root_source_file = output_dir.path(b, "protocols.zig");
        protocols.addImport("hyprwire", hyprwire);

        return scanner;
    }

    /// Scan the protocol xml at the given path.
    pub fn addCustomProtocol(self: *Self, path: Build.LazyPath) void {
        self.run.addArg("-i");
        self.run.addFileArg(path);
    }

    /// Generate code for the given protocol name at the given version,
    /// as well as all interfaces that can be created using it at that version.
    /// If the version found in the protocol xml is less than the requested version,
    /// an error will be printed and code generation will fail.
    pub fn generate(self: *Self, protocol_name: []const u8, version: u32) void {
        var buffer: [32]u8 = undefined;
        const version_str = std.fmt.bufPrint(&buffer, "{}", .{version}) catch unreachable;

        self.run.addArgs(&.{ "-p", protocol_name, version_str });
    }
};
