const std = @import("std");
const xml = @import("xml");
const hyprwire = @import("hyprwire");

const mem = std.mem;
const fmt = std.fmt;

const MessageMagic = hyprwire.MessageMagic;

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

pub fn generateClientCode(doc: *const Document) []const u8 {
    _ = doc;
    const source =
        \\ test
        \\ client
        \\ code
    ;

    return source;
}

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

fn generateMethodParams(method: *const Node.Element, gpa: mem.Allocator) ![]const u8 {
    var params: std.ArrayList(u8) = .empty;
    errdefer params.deinit(gpa);

    for (method.children) |child| {
        switch (child) {
            .element => |e| {
                if (mem.eql(u8, e.name, "arg")) {}
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

    return try output.toOwnedSlice(gpa);
}
