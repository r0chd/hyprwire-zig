const std = @import("std");
const xml = @import("xml");
const hyprwire = @import("hyprwire");

const mem = std.mem;

const Build = std.Build;

const Self = @This();

pub const Options = struct {};

pub fn init(b: *Build, options: Options) Self {
    _ = b;
    _ = options;

    return .{};
}

pub fn addCustomProtocol(self: *Self, path: Build.LazyPath) void {
    _ = self;
    _ = path;
}

pub fn generate(self: *Self, interface: []const u8, version: u32) void {
    _ = self;
    _ = interface;
    _ = version;
}

fn generateClientCode(gpa: mem.Allocator, doc: *const Document) ![]const u8 {
    _ = doc;

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    const writer = output.writer(gpa);

    try writer.print(
        \\ test
        \\ server
        \\ scanner
    , .{});

    return try output.toOwnedSlice(gpa);
}

fn generateServerCode(gpa: mem.Allocator, doc: *const Document) ![]const u8 {
    _ = doc;

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    const writer = output.writer(gpa);

    try writer.print(
        \\ test
        \\ server
        \\ scanner
    , .{});

    return try output.toOwnedSlice(gpa);
}

const Document = struct {
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
