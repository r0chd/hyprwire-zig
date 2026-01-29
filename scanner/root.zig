const std = @import("std");
const mem = std.mem;
const xml = @import("xml");
const build_options = @import("build_options");
const version = build_options.version;

/// Scanner signature - easily editable for customization
pub const SCANNER_SIGNATURE = "Generated with hyprwire-scanner " ++ version ++ ". Made with pure malice and hatred by r0chd.";

pub const ir = @import("ir.zig");
const Object = ir.Object;
const Method = ir.Method;
pub const generateClientCodeForGlobal = @import("client.zig").generateClientCodeForGlobal;
pub const generateSpecCodeForGlobal = @import("spec.zig").generateSpecCodeForGlobal;
pub const generateServerCodeForGlobal = @import("server.zig").generateServerCodeForGlobal;

pub const MessageMagic = enum(u8) {
    /// Signifies an end of a message
    end = 0x0,

    /// Primitive type identifiers
    type_uint = 0x10,
    type_int = 0x11,
    type_f32 = 0x12,
    type_seq = 0x13,
    type_object_id = 0x14,

    /// Variable length types
    /// [magic : 1B][len : VLQ][data : len B]
    type_varchar = 0x20,

    /// [magic : 1B][type : 1B][n_els : VLQ]{ [data...] }
    type_array = 0x21,

    /// [magic : 1B][id : UINT][name_len : VLQ][object name ...]
    type_object = 0x22,

    /// Special types
    /// FD has size 0. It's passed via control.
    type_fd = 0x40,
};

pub const GenerateError = error{
    ProtocolVersionTooLow,
    UnknownGlobalInterface,
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

pub const Node = union(enum) {
    element: Element,
    text: []const u8,

    pub const Element = struct {
        name: []const u8,
        attributes: std.StringArrayHashMapUnmanaged([]const u8),
        children: []const Node,
    };
};

pub fn findProtocolElement(doc: *const Document) ?Node.Element {
    for (doc.root_nodes) |node| {
        switch (node) {
            .element => |e| if (mem.eql(u8, e.name, "protocol")) return e,
            else => {},
        }
    }
    return null;
}

pub fn writeMethodHandler(writer: anytype, obj: Object, method: Method, idx: usize) !void {
    try writer.print("\nfn {s}_method{}(r: *types.Object", .{ obj.name_camel, idx });

    for (method.args) |arg| {
        if (arg.is_array) {
            if (mem.eql(u8, arg.type_str, "fd")) {
                try writer.print(", {s}: [*]const i32, {s}_len: u32", .{ arg.name, arg.name });
            } else {
                try writer.print(", {s}: {s}, {s}_len: u32", .{ arg.name, arg.zig_server_event_type, arg.name });
            }
        } else if (mem.eql(u8, arg.type_str, "enum") or
            mem.eql(u8, arg.type_str, "fd"))
        {
            try writer.print(", {s}: i32", .{arg.name});
        } else {
            if (method.returns_type.len > 0) {
                try writer.print(", {s}: u32", .{arg.name});
            } else {
                try writer.print(", {s}: {s}", .{ arg.name, arg.zig_server_event_type });
            }
        }
    }

    if (method.args.len == 0 and method.returns_type.len > 0) {
        try writer.print(", seq: u32", .{});
    }

    try writer.print(
        \\) callconv(.c) void {{
        \\    const object: *{s}Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
        \\    defer _ = object.arena.reset(.retain_capacity);
        \\    var buffer: [32_768]u8 = undefined;
        \\    var fba = std.heap.FixedBufferAllocator.init(&buffer);
        \\    var fallback_allocator = hyprwire.FallbackAllocator{{
        \\        .fba = &fba,
        \\        .fixed = fba.allocator(),
        \\        .fallback = object.arena.allocator(),
        \\    }};
        \\    object.listener.vtable.{s}Listener(
        \\        object.listener.ptr,
        \\        fallback_allocator.allocator(),
    , .{ obj.name_pascal, obj.name_camel });

    if (method.args.len == 0 and method.returns_type.len == 0) {
        try writer.print(
            \\
            \\        .{{ .@"{s}" = .{{}} }},
            \\    );
            \\}}
            \\
        , .{method.name});
        return;
    }

    try writer.print(
        \\
        \\        .{{ .@"{s}" = .{{
    , .{method.name});

    if (method.args.len == 0) {
        if (method.returns_type.len > 0) {
            try writer.print(
                \\
                \\            .seq = seq,
            , .{});
        }
    } else {
        for (method.args) |arg| {
            if (arg.is_array) {
                if (mem.eql(u8, arg.base_type, "varchar")) {
                    try writer.print(
                        \\
                        \\            .@"{s}" = fallback_allocator.allocator().dupe([*:0]const u8, {s}[0..{s}_len]) catch @panic("OOM"),
                    , .{ arg.name, arg.name, arg.name });
                } else if (mem.eql(u8, arg.base_type, "uint")) {
                    try writer.print(
                        \\
                        \\            .@"{s}" = fallback_allocator.allocator().dupe(u32, {s}[0..{s}_len]) catch @panic("OOM"),
                    , .{ arg.name, arg.name, arg.name });
                } else if (mem.eql(u8, arg.base_type, "fd")) {
                    try writer.print(
                        \\
                        \\            .@"{s}" = fallback_allocator.allocator().dupe(i32, {s}[0..{s}_len]) catch @panic("OOM"),
                    , .{ arg.name, arg.name, arg.name });
                }
            } else if (mem.eql(u8, arg.type_str, "enum")) {
                try writer.print(
                    \\
                    \\            .@"{s}" = @enumFromInt({s}),
                , .{ arg.name, arg.name });
            } else if (mem.eql(u8, arg.type_str, "fd")) {
                try writer.print(
                    \\
                    \\            .@"{s}" = {s},
                , .{ arg.name, arg.name });
            } else if (method.returns_type.len > 0) {
                try writer.print(
                    \\
                    \\            .{s} = {s},
                , .{ arg.name, arg.name });
            } else {
                try writer.print(
                    \\
                    \\            .@"{s}" = {s},
                , .{ arg.name, arg.name });
            }
        }
    }

    try writer.print(
        \\
        \\        }} }},
        \\    );
        \\}}
        \\
    , .{});
}

test {
    std.testing.refAllDecls(@This());
}
