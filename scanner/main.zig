const std = @import("std");
const xml = @import("xml");
const Cli = @import("Cli.zig");
const Scanner = @import("./root.zig");

const log = std.log.scoped(.hw);
const mem = std.mem;
const process = std.process;
const ascii = std.ascii;
const fmt = std.fmt;
const heap = std.heap;
const fs = std.fs;

const Document = Scanner.Document;

const ProtoData = struct {
    name: []const u8,
    name_original: []const u8,
    file_name: []const u8,
    version: u32 = 1,

    const Self = @This();

    fn init(gpa: mem.Allocator, proto_path: []const u8, document: *const Document) !Self {
        const protocol_element = blk: for (document.root_nodes) |node| {
            switch (node) {
                .element => |e| if (mem.eql(u8, e.name, "protocol")) break :blk e,
                else => {},
            }
        } else {
            log.err("No protocol element found\n", .{});
            process.exit(1);
        };

        const name_original = protocol_element.attributes.get("name") orelse {
            log.err("Protocol missing name attribute\n", .{});
            process.exit(1);
        };

        const version = protocol_element.attributes.get("version") orelse "1";

        const last_slash = mem.lastIndexOfScalar(u8, proto_path, '/');
        const last_dot = mem.lastIndexOfScalar(u8, proto_path, '.');
        const file_name = if (last_slash) |slash|
            (if (last_dot) |dot| proto_path[slash + 1 .. dot] else proto_path[slash + 1 ..])
        else
            (if (last_dot) |dot| proto_path[0..dot] else proto_path);

        var name_buf: [256]u8 = undefined;
        const name_len = @min(name_original.len, name_buf.len);
        @memcpy(name_buf[0..name_len], name_original[0..name_len]);
        if (name_len > 0) {
            name_buf[0] = ascii.toUpper(name_buf[0]);
        }
        const name = try gpa.dupe(u8, name_buf[0..name_len]);

        return ProtoData{
            .name = name,
            .name_original = name_original,
            .file_name = file_name,
            .version = try fmt.parseInt(u32, version, 10),
        };
    }
};

pub fn main() !void {
    const alloc = heap.page_allocator;

    const cli = Cli.init(alloc) catch |err| switch (err) {
        error.TooManyArguments => {
            log.err("Too many arguments\n", .{});
            process.exit(1);
        },
        error.MissingOutPath => {
            log.err("Missing out path argument\n", .{});
            process.exit(1);
        },
        error.MissingProtoPath => {
            log.err("Missing proto path argument\n", .{});
            process.exit(1);
        },
        error.MissingInputPath => {
            log.err("Missing input path argument\n", .{});
            process.exit(1);
        },
        error.MissingOutputPath => {
            log.err("Missing output path argument\n", .{});
            process.exit(1);
        },
        else => {
            return err;
        },
    };

    var input_file = try fs.cwd().openFile(cli.protopath, .{});
    defer input_file.close();

    var input_buf: [4096]u8 = undefined;
    var input_reader = input_file.reader(&input_buf);
    var streaming_reader: xml.Reader.Streaming = .init(alloc, &input_reader.interface, .{});
    const reader = &streaming_reader.interface;

    const document = try Document.parse(alloc, reader);

    const proto_data = try ProtoData.init(alloc, cli.protopath, &document);

    if (cli.protocols.len == 0) {
        try writeGenerated(alloc, cli.outpath, proto_data.name_original, &document, .client);
        try writeGenerated(alloc, cli.outpath, proto_data.name_original, &document, .server);
        try writeGenerated(alloc, cli.outpath, proto_data.name_original, &document, .spec);
        try writeWrapper(alloc, cli.outpath, proto_data.name_original);
        return;
    }

    for (cli.protocols) |p| {
        const base_name = p.name;

        const client_src = Scanner.generateClientCodeForGlobal(alloc, &document, p.name, p.version) catch |err| {
            switch (err) {
                Scanner.GenerateError.ProtocolVersionTooLow => {
                    log.err("Protocol xml version ({}) is less than requested version ({})\n", .{ proto_data.version, p.version });
                    process.exit(1);
                },
                Scanner.GenerateError.UnknownGlobalInterface => {
                    log.err("Unknown global interface '{s}'\n", .{p.name});
                    process.exit(1);
                },
                else => return err,
            }
        };
        defer alloc.free(client_src);

        const server_src = Scanner.generateServerCodeForGlobal(alloc, &document, p.name, p.version) catch |err| {
            switch (err) {
                Scanner.GenerateError.ProtocolVersionTooLow => {
                    log.err("Protocol xml version ({}) is less than requested version ({})\n", .{ proto_data.version, p.version });
                    process.exit(1);
                },
                Scanner.GenerateError.UnknownGlobalInterface => {
                    log.err("Unknown global interface '{s}'\n", .{p.name});
                    process.exit(1);
                },
                else => return err,
            }
        };
        defer alloc.free(server_src);

        const spec_src = Scanner.generateSpecCodeForGlobal(alloc, &document, p.name, p.version) catch |err| {
            switch (err) {
                Scanner.GenerateError.ProtocolVersionTooLow => {
                    log.err("Protocol xml version ({}) is less than requested version ({})\n", .{ proto_data.version, p.version });
                    process.exit(1);
                },
                Scanner.GenerateError.UnknownGlobalInterface => {
                    log.err("Unknown global interface '{s}'\n", .{p.name});
                    process.exit(1);
                },
                else => return err,
            }
        };
        defer alloc.free(spec_src);

        const client_filename = try std.fmt.allocPrint(alloc, "{s}-client.zig", .{base_name});
        defer alloc.free(client_filename);
        const server_filename = try std.fmt.allocPrint(alloc, "{s}-server.zig", .{base_name});
        defer alloc.free(server_filename);
        const spec_filename = try std.fmt.allocPrint(alloc, "{s}-spec.zig", .{base_name});
        defer alloc.free(spec_filename);

        const client_path = try std.fs.path.join(alloc, &.{ cli.outpath, client_filename });
        defer alloc.free(client_path);
        const server_path = try std.fs.path.join(alloc, &.{ cli.outpath, server_filename });
        defer alloc.free(server_path);
        const spec_path = try std.fs.path.join(alloc, &.{ cli.outpath, spec_filename });
        defer alloc.free(spec_path);

        if (std.fs.path.dirname(client_path)) |dir| {
            try std.fs.cwd().makePath(dir);
        }

        var client_file = try std.fs.cwd().createFile(client_path, .{ .truncate = true });
        defer client_file.close();
        _ = try client_file.write(client_src);

        var server_file = try std.fs.cwd().createFile(server_path, .{ .truncate = true });
        defer server_file.close();
        _ = try server_file.write(server_src);

        var spec_file = try std.fs.cwd().createFile(spec_path, .{ .truncate = true });
        defer spec_file.close();
        _ = try spec_file.write(spec_src);

        try writeWrapper(alloc, cli.outpath, base_name);
    }

    try writeProtocolsIndex(alloc, cli.outpath, cli.protocols);
}

fn writeProtocolsIndex(
    alloc: std.mem.Allocator,
    outpath: []const u8,
    protocols: []const Cli.Protocol,
) !void {
    var content: std.Io.Writer.Allocating = .init(alloc);
    var writer = &content.writer;

    for (protocols) |p| {
        try writer.print("pub const {s} = @import(\"{s}.zig\");\n", .{ p.name, p.name });
    }

    const file_path = try std.fs.path.join(alloc, &.{ outpath, "protocols.zig" });
    defer alloc.free(file_path);

    if (std.fs.path.dirname(file_path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    var file = try std.fs.cwd().createFile(file_path, .{ .truncate = true });
    defer file.close();

    _ = try file.write(content.written());
}

const GeneratedKind = enum {
    client,
    server,
    spec,
};

fn writeGenerated(
    alloc: std.mem.Allocator,
    outpath: []const u8,
    base_name: []const u8,
    document: *const Document,
    kind: GeneratedKind,
) !void {
    const component = switch (kind) {
        .client => "client",
        .server => "server",
        .spec => "spec",
    };

    const source = switch (kind) {
        .client => try Scanner.generateClientCode(alloc, document),
        .server => try Scanner.generateServerCode(alloc, document),
        .spec => try Scanner.generateSpecCode(alloc, document),
    };

    const filename = try std.fmt.allocPrint(alloc, "{s}-{s}.zig", .{ base_name, component });
    defer alloc.free(filename);

    const file_path = try std.fs.path.join(alloc, &.{ outpath, filename });
    defer alloc.free(file_path);

    if (std.fs.path.dirname(file_path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    var file = try std.fs.cwd().createFile(file_path, .{ .truncate = true });
    defer file.close();

    _ = try file.write(source);
}

fn writeSingleGenerated(
    alloc: std.mem.Allocator,
    outpath: []const u8,
    document: *const Document,
    kind: GeneratedKind,
) !void {
    const source = switch (kind) {
        .client => try Scanner.generateClientCode(alloc, document),
        .server => try Scanner.generateServerCode(alloc, document),
        .spec => try Scanner.generateSpecCode(alloc, document),
    };

    var file = try std.fs.cwd().createFile(outpath, .{ .truncate = true });
    defer file.close();

    _ = try file.write(source);
}

fn appendToGeneratedFile(
    alloc: std.mem.Allocator,
    outpath: []const u8,
    document: *const Document,
    kind: GeneratedKind,
) !void {
    const source = switch (kind) {
        .client => try Scanner.generateClientCode(alloc, document),
        .server => try Scanner.generateServerCode(alloc, document),
        .spec => try Scanner.generateSpecCode(alloc, document),
    };

    var file = try std.fs.cwd().openFile(outpath, .{ .mode = .write_only });
    defer file.close();

    _ = try file.write(source);
}

fn writeWrapper(
    alloc: std.mem.Allocator,
    outpath: []const u8,
    base_name: []const u8,
) !void {
    const content = try std.fmt.allocPrint(alloc,
        \\pub const server = @import("{s}-server.zig");
        \\pub const client = @import("{s}-client.zig");
        \\pub const spec = @import("{s}-spec.zig");
    , .{ base_name, base_name, base_name });
    defer alloc.free(content);

    const filename = try std.fmt.allocPrint(alloc, "{s}.zig", .{base_name});
    defer alloc.free(filename);

    const file_path = try std.fs.path.join(alloc, &.{ outpath, filename });
    defer alloc.free(file_path);

    if (std.fs.path.dirname(file_path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    var file = try std.fs.cwd().createFile(file_path, .{ .truncate = true });
    defer file.close();

    _ = try file.write(content);
}
