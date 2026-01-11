const std = @import("std");
const xml = @import("xml");
const Cli = @import("Cli.zig");

const log = std.log;
const mem = std.mem;
const process = std.process;
const ascii = std.ascii;
const fmt = std.fmt;
const heap = std.heap;
const fs = std.fs;

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

pub const Document = struct {
    root_nodes: []const Node,

    pub fn parse(arena: mem.Allocator, reader: *xml.Reader) !Document {
        var root_nodes: std.ArrayList(Node) = .empty;
        while (true) {
            const node = try reader.read();
            switch (node) {
                .eof => break,
                .element_start => try root_nodes.append(arena, .{ .element = try parseElement(arena, reader) }),
                .element_end => unreachable,
                .text, .cdata, .character_reference, .entity_reference => unreachable,
                else => continue,
            }
        }
        return .{ .root_nodes = try root_nodes.toOwnedSlice(arena) };
    }

    fn parseElement(arena: mem.Allocator, reader: *xml.Reader) !Node.Element {
        const name = try arena.dupe(u8, reader.elementName());
        var attributes: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        for (0..reader.attributeCount()) |i| {
            try attributes.put(
                arena,
                try arena.dupe(u8, reader.attributeName(i)),
                try reader.attributeValueAlloc(arena, i),
            );
        }

        var children: std.ArrayList(Node) = .empty;
        var text: std.Io.Writer.Allocating = .init(arena);
        while (true) {
            const node = try reader.read();
            switch (node) {
                .eof, .xml_declaration => unreachable,
                .element_start => {
                    if (text.written().len > 0) {
                        try children.append(arena, .{ .text = try text.toOwnedSlice() });
                    }
                    try children.append(arena, .{ .element = try parseElement(arena, reader) });
                },
                .element_end => break,
                .comment => continue,
                .text => reader.textWrite(&text.writer) catch |err| switch (err) {
                    error.WriteFailed => return error.OutOfMemory,
                },
                else => {},
            }
        }
        if (text.written().len > 0) {
            try children.append(arena, .{ .text = try text.toOwnedSlice() });
        }

        return .{
            .name = name,
            .attributes = attributes,
            .children = try children.toOwnedSlice(arena),
        };
    }
};

const Node = union(enum) {
    element: Element,
    text: []const u8,

    const Element = struct {
        name: []const u8,
        attributes: std.StringArrayHashMapUnmanaged([]const u8),
        children: []const Node,
    };
};

pub fn generateClientCode(doc: *const Document) []const u8 {
    _ = doc;
    const source =
        \\ test
        \\ client
        \\ code
    ;

    return source;
}

const MessageMagic = struct {
    pub const type_array: u8 = 0x21;
    pub const type_varchar: u8 = 0x20;
    pub const type_uint: u8 = 0x10;
    pub const type_int: u8 = 0x11;
    pub const type_fd: u8 = 0x40;
    pub const type_seq: u8 = 0x13;
};

fn findProtocolElement(doc: *const Document) ?Node.Element {
    for (doc.root_nodes) |node| {
        switch (node) {
            .element => |e| if (mem.eql(u8, e.name, "protocol")) return e,
            else => {},
        }
    }
    return null;
}

fn findChildElements(element: *const Node.Element, name: []const u8) std.ArrayList(*const Node.Element) {
    var result: std.ArrayList(*const Node.Element) = .empty;
    for (element.children) |child| {
        switch (child) {
            .element => |e| if (mem.eql(u8, e.name, name)) {
                result.append(std.heap.page_allocator, &e) catch {};
            },
            else => {},
        }
    }
    return result;
}

fn parseType(type_str: []const u8, gpa: mem.Allocator) ![]const u8 {
    if (mem.startsWith(u8, type_str, "array ")) {
        const element_type = type_str[6..];
        const element_magic = try parseType(element_type, gpa);
        defer gpa.free(element_magic);
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(gpa);
        try result.append(gpa, MessageMagic.type_array);
        try result.appendSlice(gpa, element_magic);
        return try result.toOwnedSlice(gpa);
    } else if (mem.eql(u8, type_str, "varchar")) {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(gpa);
        try result.append(gpa, MessageMagic.type_varchar);
        return try result.toOwnedSlice(gpa);
    } else if (mem.eql(u8, type_str, "uint")) {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(gpa);
        try result.append(gpa, MessageMagic.type_uint);
        return try result.toOwnedSlice(gpa);
    } else if (mem.eql(u8, type_str, "int")) {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(gpa);
        try result.append(gpa, MessageMagic.type_int);
        return try result.toOwnedSlice(gpa);
    } else if (mem.eql(u8, type_str, "fd")) {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(gpa);
        try result.append(gpa, MessageMagic.type_fd);
        return try result.toOwnedSlice(gpa);
    } else if (mem.eql(u8, type_str, "enum")) {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(gpa);
        try result.append(gpa, MessageMagic.type_uint);
        return try result.toOwnedSlice(gpa);
    } else {
        return error.UnknownType;
    }
}

fn generateMethodParams(method: *const Node.Element, gpa: mem.Allocator) ![]const u8 {
    var params: std.ArrayList(u8) = .empty;
    errdefer params.deinit(gpa);

    for (method.children) |child| {
        switch (child) {
            .element => |e| {
                if (mem.eql(u8, e.name, "arg")) {
                    const type_attr = e.attributes.get("type") orelse return error.MissingType;
                    const param_bytes = try parseType(type_attr, gpa);
                    defer gpa.free(param_bytes);
                    try params.appendSlice(gpa, param_bytes);
                }
            },
            else => {},
        }
    }

    return try params.toOwnedSlice(gpa);
}

fn hasReturns(method: *const Node.Element) bool {
    for (method.children) |child| {
        switch (child) {
            .element => |e| if (mem.eql(u8, e.name, "returns")) return true,
            else => {},
        }
    }
    return false;
}

pub fn generateServerCode(gpa: mem.Allocator, doc: *const Document) ![]const u8 {
    const protocol_elem = findProtocolElement(doc) orelse return error.NoProtocolElement;
    const protocol_name = protocol_elem.attributes.get("name") orelse return error.MissingProtocolName;
    const protocol_version_str = protocol_elem.attributes.get("version") orelse "1";
    const protocol_version = try fmt.parseInt(u32, protocol_version_str, 10);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    const writer = output.writer(gpa);

    try writer.print(
        \\const types = @import("hyprwire").types;
        \\const MessageMagic = @import("hyprwire").MessageMagic;
        \\
        \\const Method = types.Method;
        \\const ProtocolSpec = types.ProtocolSpec;
        \\const ProtocolObjectSpec = types.ProtocolObjectSpec;
        \\
        \\pub const spec = ProtocolSpec{{
        \\    .spec_name = "{s}",
        \\    .spec_ver = {},
        \\    .objects = &.{{
    , .{ protocol_name, protocol_version });

    var object_idx: u32 = 0;
    for (protocol_elem.children) |child| {
        switch (child) {
            .element => |e| {
                if (!mem.eql(u8, e.name, "object")) continue;

                const object_name = e.attributes.get("name") orelse return error.MissingObjectName;
                const object_version_str = e.attributes.get("version") orelse "1";
                const object_version = try fmt.parseInt(u32, object_version_str, 10);

                var c2s_methods: std.ArrayList(*const Node.Element) = .empty;
                var s2c_methods: std.ArrayList(*const Node.Element) = .empty;

                for (e.children) |method_child| {
                    switch (method_child) {
                        .element => |method_elem| {
                            if (mem.eql(u8, method_elem.name, "c2s")) {
                                try c2s_methods.append(gpa, &method_elem);
                            } else if (mem.eql(u8, method_elem.name, "s2c")) {
                                try s2c_methods.append(gpa, &method_elem);
                            }
                        },
                        else => {},
                    }
                }

                try writer.print(
                    \\
                    \\        ProtocolObjectSpec{{
                    \\            .object_name = "{s}",
                    \\            .c2s_methods = &.{{
                , .{object_name});
                try writer.writeAll("\n");

                for (c2s_methods.items, 0..) |method, idx| {
                    try writer.writeAll("                ");
                    const params = try generateMethodParams(method, gpa);
                    defer gpa.free(params);
                    const has_returns = hasReturns(method);
                    const returns_type = if (has_returns) "@intFromEnum(MessageMagic.type_seq)" else "\"\"";

                    try writer.print("Method{{ .idx = {}, .params = &[_]u8{{", .{idx});
                    if (params.len > 0) {
                        for (params, 0..) |byte, i| {
                            if (i > 0) try writer.writeAll(", ");
                            const magic_name = switch (byte) {
                                MessageMagic.type_array => "type_array",
                                MessageMagic.type_varchar => "type_varchar",
                                MessageMagic.type_uint => "type_uint",
                                MessageMagic.type_int => "type_int",
                                MessageMagic.type_fd => "type_fd",
                                MessageMagic.type_seq => "type_seq",
                                else => return error.UnknownMagicType,
                            };
                            try writer.print("@intFromEnum(MessageMagic.{s})", .{magic_name});
                        }
                    }

                    try writer.print("}}, .returns_type = {s}, .since = {} }},\n", .{ returns_type, object_version });
                }

                try writer.writeAll(
                    \\            },
                    \\            .s2c_methods = &.{
                );
                try writer.writeAll("\n");

                for (s2c_methods.items, 0..) |method, idx| {
                    const params = try generateMethodParams(method, gpa);
                    defer gpa.free(params);
                    const has_returns = hasReturns(method);
                    const returns_type = if (has_returns) "@intFromEnum(MessageMagic.type_seq)" else "\"\"";

                    try writer.print("                Method{{ .idx = {}, .params = &[_]u8{{", .{idx});

                    if (params.len > 0) {
                        for (params, 0..) |byte, i| {
                            if (i > 0) try writer.writeAll(", ");
                            const magic_name = switch (byte) {
                                MessageMagic.type_array => "type_array",
                                MessageMagic.type_varchar => "type_varchar",
                                MessageMagic.type_uint => "type_uint",
                                MessageMagic.type_int => "type_int",
                                MessageMagic.type_fd => "type_fd",
                                MessageMagic.type_seq => "type_seq",
                                else => return error.UnknownMagicType,
                            };
                            try writer.print("@intFromEnum(MessageMagic.{s})", .{magic_name});
                        }
                    }

                    try writer.print("}}, .returns_type = {s}, .since = {} }},\n", .{ returns_type, object_version });
                }

                try writer.writeAll(
                    \\            },
                    \\        },
                );

                object_idx += 1;
            },
            else => {},
        }
    }

    try writer.writeAll(
        \\
        \\    },
        \\};
    );

    return try output.toOwnedSlice(gpa);
}

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
        .client => generateClientCode(&document),
        .server => try generateServerCode(alloc, &document),
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
