const std = @import("std");
const xml = @import("xml");
const Cli = @import("Cli.zig");
const Scanner = @import("./root.zig");

const log = std.log.scoped(.hw);
const mem = std.mem;
const process = std.process;
const ascii = std.ascii;
const fmt = std.fmt;

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

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();

    const cli = Cli.init(alloc, init.minimal.args) catch |err| switch (err) {
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

    var input_file = try std.Io.Dir.cwd().openFile(init.io, cli.protopath, .{});
    defer input_file.close(init.io);

    var input_buf: [4096]u8 = undefined;
    var input_reader = input_file.reader(init.io, &input_buf);
    var streaming_reader: xml.Reader.Streaming = .init(alloc, &input_reader.interface, .{});
    const reader = &streaming_reader.interface;

    const document = try Document.parse(alloc, reader);

    const proto_data = try ProtoData.init(alloc, cli.protopath, &document);

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

        const client_filename = try std.fmt.allocPrint(alloc, "{s}-client.zig", .{base_name});
        const server_filename = try std.fmt.allocPrint(alloc, "{s}-server.zig", .{base_name});
        const spec_filename = try std.fmt.allocPrint(alloc, "{s}-spec.zig", .{base_name});

        const client_path = try std.fs.path.join(alloc, &.{ cli.outpath, client_filename });
        const server_path = try std.fs.path.join(alloc, &.{ cli.outpath, server_filename });
        const spec_path = try std.fs.path.join(alloc, &.{ cli.outpath, spec_filename });

        if (std.fs.path.dirname(client_path)) |dir| {
            try std.Io.Dir.cwd().createDirPath(init.io, dir);
        }

        var client_file = try std.Io.Dir.cwd().createFile(init.io, client_path, .{ .truncate = true });
        defer client_file.close(init.io);
        {
            var buffer: [1024]u8 = undefined;
            var writer = client_file.writer(init.io, &buffer);
            try writer.interface.writeAll(client_src);
            try writer.interface.writeByte('\n');
        }

        var server_file = try std.Io.Dir.cwd().createFile(init.io, server_path, .{ .truncate = true });
        defer server_file.close(init.io);
        {
            var buffer: [1024]u8 = undefined;
            var writer = server_file.writer(init.io, &buffer);
            try writer.interface.writeAll(server_src);
            try writer.interface.writeByte('\n');
        }

        var spec_file = try std.Io.Dir.cwd().createFile(init.io, spec_path, .{ .truncate = true });
        defer spec_file.close(init.io);
        {
            var buffer: [1024]u8 = undefined;
            var writer = spec_file.writer(init.io, &buffer);
            try writer.interface.writeAll(spec_src);
            try writer.interface.writeByte('\n');
        }

        try writeWrapper(alloc, init.io, cli.outpath, base_name);
    }

    try writeProtocolsIndex(alloc, init.io, cli.outpath, cli.protocols);
}

fn writeProtocolsIndex(
    alloc: std.mem.Allocator,
    io: std.Io,
    outpath: []const u8,
    protocols: []const Cli.Protocol,
) !void {
    const file_path = try std.fs.path.join(alloc, &.{ outpath, "protocols.zig" });
    defer alloc.free(file_path);

    if (std.fs.path.dirname(file_path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }

    var file = try std.Io.Dir.cwd().createFile(io, file_path, .{ .truncate = true });
    defer file.close(io);
    {
        var buffer: [1024]u8 = undefined;
        var writer = file.writer(io, &buffer);
        var iowriter = &writer.interface;
        for (protocols) |p| {
            try iowriter.print("pub const {s} = @import(\"{s}.zig\");\n", .{ p.name, p.name });
        }
        try iowriter.flush();
    }
}

fn writeWrapper(
    alloc: std.mem.Allocator,
    io: std.Io,
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
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }

    var client_file = try std.Io.Dir.cwd().createFile(io, file_path, .{ .truncate = true });
    defer client_file.close(io);
    {
        var buffer: [1024]u8 = undefined;
        var writer = client_file.writer(io, &buffer);
        var iowriter = &writer.interface;
        try iowriter.writeAll(content);
        try iowriter.flush();
    }
}

test {
    std.testing.refAllDecls(@This());
}
