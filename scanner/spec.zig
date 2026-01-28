const std = @import("std");
const mem = std.mem;

const root = @import("root.zig");
const Document = root.Document;
const MessageMagic = root.MessageMagic;
const GenerateError = root.GenerateError;

const ir = @import("ir.zig");
const Protocol = ir.Protocol;
const Object = ir.Object;
const Method = ir.Method;
const ObjectSet = ir.ObjectSet;

pub fn generateSpecCodeForGlobal(gpa: mem.Allocator, doc: *const Document, global_iface: []const u8, requested_version: u32) ![]const u8 {
    const protocol = try Protocol.fromDocument(doc, gpa);

    if (protocol.version < requested_version) {
        return GenerateError.ProtocolVersionTooLow;
    }

    if (mem.eql(u8, global_iface, protocol.name)) {
        return generateSpecCode(gpa, protocol, null);
    }

    const selected = try protocol.computeReachableSet(gpa, global_iface, requested_version);
    return generateSpecCode(gpa, protocol, selected);
}

fn generateSpecCode(gpa: mem.Allocator, protocol: Protocol, selected: ?ObjectSet) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    const writer = &output.writer;

    try writeHeader(writer);
    try writeEnums(writer, protocol);
    try writeObjectSpecs(writer, gpa, protocol, selected);
    try writeProtocolSpec(writer, protocol, selected);

    return try output.toOwnedSlice();
}

fn writeHeader(writer: anytype) !void {
    try writer.print(
        \\const std = @import("std");
        \\
        \\const hyprwire = @import("hyprwire");
        \\const types = hyprwire.types;
        \\
    , .{});
}

fn writeEnums(writer: anytype, protocol: Protocol) !void {
    for (protocol.enums) |enum_info| {
        try writer.print("\npub const {s} = enum(u32) {{\n", .{enum_info.name_pascal});
        for (enum_info.values) |value| {
            try writer.print("   {s} = {},\n", .{ value.name, value.idx });
        }
        try writer.print("}};\n", .{});
    }
}

fn writeObjectSpecs(writer: anytype, gpa: mem.Allocator, protocol: Protocol, selected: ?ObjectSet) !void {
    for (protocol.objects) |obj| {
        if (selected) |sel| {
            if (!sel.contains(obj.name)) continue;
        }
        try writeObjectSpec(writer, gpa, obj);
    }
}

fn writeObjectSpec(writer: anytype, gpa: mem.Allocator, obj: Object) !void {
    _ = gpa;
    try writer.print("\npub const {s}Spec = struct {{\n", .{obj.name_pascal});

    try writer.print("    c2s_methods: []const types.Method = &.{{\n", .{});
    for (obj.c2s_methods) |method| {
        try writeMethodSpec(writer, method, true);
    }
    try writer.print("    }},\n\n", .{});

    try writer.print("    s2c_methods: []const types.Method = &.{{\n", .{});
    for (obj.s2c_methods) |method| {
        try writeMethodSpec(writer, method, false);
    }
    try writer.print("    }},\n\n", .{});

    try writer.print(
        \\    const Self = @This();
        \\
        \\    pub fn objectName(_: *const Self) []const u8 {{
        \\        return "{s}";
        \\    }}
        \\
        \\    pub fn c2s(self: *const Self) []const types.Method {{
        \\        return self.c2s_methods;
        \\    }}
        \\
        \\    pub fn s2c(self: *const Self) []const types.Method {{
        \\        return self.s2c_methods;
        \\    }}
        \\}};
        \\
    , .{obj.name});
}

fn writeMethodSpec(writer: anytype, method: Method, is_c2s: bool) !void {
    try writer.print(
        \\        .{{
        \\            .idx = {},
        \\            .params = &[_]u8{{
    , .{method.idx});

    for (method.params, 0..) |param_byte, i| {
        if (i > 0) try writer.print(", ", .{});
        try writer.print("@intFromEnum(hyprwire.MessageMagic.{s})", .{@tagName(@as(MessageMagic, @enumFromInt((param_byte))))});
    }

    if (is_c2s) {
        try writer.print(
            \\}},
            \\            .returns_type = "{s}",
            \\            .since = {},
            \\        }},
            \\
        , .{ method.returns_type, method.since });
    } else {
        try writer.print(
            \\}},
            \\            .since = {},
            \\        }},
            \\
        , .{method.since});
    }
}

fn writeProtocolSpec(writer: anytype, protocol: Protocol, selected: ?ObjectSet) !void {
    var obj_count: usize = 0;
    for (protocol.objects) |obj| {
        if (selected) |sel| {
            if (!sel.contains(obj.name)) continue;
        }
        obj_count += 1;
    }

    try writer.print("\npub const {s}ProtocolSpec = struct {{\n", .{protocol.name_pascal});

    for (protocol.objects) |obj| {
        if (selected) |sel| {
            if (!sel.contains(obj.name)) continue;
        }
        try writer.print("    {s}: {s}Spec = .{{}},\n", .{ obj.name_camel, obj.name_pascal });
    }

    try writer.print(
        \\
        \\    const Self = @This();
        \\
        \\    pub fn specName(_: *const Self) []const u8 {{
        \\        return "{s}";
        \\    }}
        \\
        \\    pub fn specVer(_: *Self) u32 {{
        \\        return {};
        \\    }}
        \\
        \\    pub fn objects(_: *Self) []const types.ProtocolObjectSpec {{
        \\        return protocol_objects[0..];
        \\    }}
        \\
        \\    pub fn deinit(_: *Self, _: std.mem.Allocator) void {{}}
        \\}};
        \\
        \\pub const protocol = {s}ProtocolSpec{{}};
        \\
        \\pub const protocol_objects: [{}]types.ProtocolObjectSpec = .{{
        \\
    , .{ protocol.name, protocol.version, protocol.name_pascal, obj_count });

    for (protocol.objects) |obj| {
        if (selected) |sel| {
            if (!sel.contains(obj.name)) continue;
        }
        try writer.print("    types.ProtocolObjectSpec.from(&protocol.{s}),\n", .{obj.name_camel});
    }

    try writer.print("}};\n", .{});
}

test {
    std.testing.refAllDecls(@This());
}
