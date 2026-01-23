const std = @import("std");
const mem = std.mem;
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

    buildExamples(b, target, optimize, hyprwire);
}

fn buildExamples(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, hyprwire: *Build.Module) void {
    const scanner = Scanner.init(b);
    scanner.addCustomProtocol(b.path("./examples/simple/protocol-v1.xml"));
    scanner.generate("test_protocol_v1");
    scanner.finalize(hyprwire);

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

pub const Scanner = struct {
    run: *Build.Step.Run,
    result: Build.LazyPath,
    output_dir: Build.LazyPath,
    b: *Build,
    generated_protocols: std.ArrayList([]const u8),

    const Self = @This();

    pub fn init(b: *Build) *Self {
        const exe = b.addExecutable(.{
            .name = "hyprwire-scanner",
            .root_module = b.createModule(.{
                .root_source_file = b.path("scanner/main.zig"),
                .target = b.graph.host,
            }),
        });

        const xml_dep = b.dependency("xml", .{
            .target = b.graph.host,
            .optimize = .Debug,
        });
        exe.root_module.addImport("xml", xml_dep.module("xml"));

        const run = b.addRunArtifact(exe);
        run.addArg("-o");
        const output_dir = run.addOutputFileArg(".");

        const scanner = b.allocator.create(Scanner) catch @panic("OOM");
        scanner.* = .{
            .run = run,
            .output_dir = output_dir,
            .b = b,
            .generated_protocols = .empty,
            .result = undefined,
        };

        return scanner;
    }

    pub fn addCustomProtocol(self: *Self, path: Build.LazyPath) void {
        self.run.addArg("-i");
        self.run.addFileArg(path);
    }

    pub fn generate(self: *Self, protocol_name: []const u8) void {
        const spec = self.b.createModule(.{
            .root_source_file = self.output_dir.path(self.b, self.b.fmt("{s}-spec.zig", .{protocol_name})),
        });
        const server = self.b.createModule(.{
            .root_source_file = self.output_dir.path(self.b, self.b.fmt("{s}-server.zig", .{protocol_name})),
        });
        const client = self.b.createModule(.{
            .root_source_file = self.output_dir.path(self.b, self.b.fmt("{s}-client.zig", .{protocol_name})),
        });
        const module = self.b.addModule(protocol_name, .{
            .root_source_file = self.output_dir.path(self.b, self.b.fmt("{s}.zig", .{protocol_name})),
        });

        module.addImport("server", server);
        module.addImport("client", client);
        module.addImport("spec", spec);

        self.generated_protocols.append(self.b.allocator, protocol_name) catch @panic("OOM");
    }

    pub fn finalize(self: *Self, hyprwire: *Build.Module) void {
        const write_files = self.b.addWriteFiles();
        write_files.step.dependOn(&self.run.step);

        var imports: std.ArrayList(u8) = .empty;
        defer imports.deinit(self.b.allocator);

        for (self.generated_protocols.items) |protocol_name| {
            imports.appendSlice(self.b.allocator, self.b.fmt("pub const {s} = @import(\"{s}\");\n", .{ protocol_name, protocol_name })) catch @panic("OOM");
        }

        const protocols_file = write_files.add("protocols.zig", imports.items);
        self.result = protocols_file;

        var protocols = hyprwire.import_table.get("protocols").?;
        protocols.root_source_file = self.result;

        for (self.generated_protocols.items) |protocol_name| {
            const protocol_module = self.b.createModule(.{
                .root_source_file = self.output_dir.path(self.b, self.b.fmt("{s}.zig", .{protocol_name})),
            });

            protocol_module.addImport("hyprwire", hyprwire);
            protocols.addImport(protocol_name, protocol_module);
        }
    }
};
