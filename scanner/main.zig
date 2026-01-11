const std = @import("std");
const xml = @import("xml");
const Cli = @import("Cli.zig");
const Scanner = @import("scanner");

const log = std.log;
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
    var arena_state: heap.ArenaAllocator = .init(heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const cli = Cli.init() catch |err| switch (err) {
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
    };

    var input_file = try fs.cwd().openFile(cli.protopath, .{});
    defer input_file.close();

    var input_buf: [4096]u8 = undefined;
    var input_reader = input_file.reader(&input_buf);
    var streaming_reader: xml.Reader.Streaming = .init(alloc, &input_reader.interface, .{});
    defer streaming_reader.deinit();
    const reader = &streaming_reader.interface;

    const document = try Document.parse(alloc, reader);

    const proto_data = try ProtoData.init(alloc, cli.protopath, &document);

    const source = switch (cli.role) {
        .client => Scanner.generateClientCode(&document),
        .server => try Scanner.generateServerCode(alloc, &document),
    };

    const outpath = cli.outpath;
    const filename = try fmt.allocPrint(alloc, "{s}{s}", .{ proto_data.name_original, if (cli.role == .client) "-client.zig" else "-server.zig" });

    const file_path = try fs.path.join(alloc, &.{ outpath, filename });

    if (fs.path.dirname(file_path)) |dir| {
        try fs.cwd().makePath(dir);
    }

    var file = try fs.cwd().createFile(file_path, .{ .truncate = true });
    defer file.close();

    _ = try file.write(source);
}
