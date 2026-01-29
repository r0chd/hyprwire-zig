const std = @import("std");
const mem = std.mem;

const fmt = std.fmt;
const root = @import("root.zig");
const Document = root.Document;
const Node = root.Node;
const MessageMagic = root.MessageMagic;

pub const Protocol = struct {
    name: []const u8,
    name_pascal: []const u8,
    version: u32,
    copyright: ?[]const u8,
    objects: []Object,
    enums: []Enum,

    pub fn fromDocument(doc: *const Document, gpa: mem.Allocator) !Protocol {
        const protocol_elem = root.findProtocolElement(doc) orelse return error.MissingProtocol;

        const name = protocol_elem.attributes.get("name") orelse return error.MissingProtocolName;
        const version_str = protocol_elem.attributes.get("version") orelse return error.MissingProtocolVersion;
        const version = try std.fmt.parseInt(u32, version_str, 10);

        var copyright: ?[]const u8 = null;

        var objects: std.ArrayList(Object) = .empty;
        var enums: std.ArrayList(Enum) = .empty;

        for (protocol_elem.children) |child| {
            switch (child) {
                .element => |e| {
                    if (mem.eql(u8, e.name, "copyright")) {
                        copyright = try extractTextContent(&e, gpa);
                    } else if (mem.eql(u8, e.name, "object")) {
                        try objects.append(gpa, try Object.fromElement(&e, gpa));
                    } else if (mem.eql(u8, e.name, "enum")) {
                        try enums.append(gpa, try Enum.fromElement(&e, gpa));
                    }
                },
                else => {},
            }
        }

        return .{
            .name = name,
            .name_pascal = try toPascalCase(name, gpa),
            .version = version,
            .copyright = copyright,
            .objects = try objects.toOwnedSlice(gpa),
            .enums = try enums.toOwnedSlice(gpa),
        };
    }

    pub fn findObject(self: *const Protocol, name: []const u8) ?*const Object {
        for (self.objects) |*obj| {
            if (mem.eql(u8, obj.name, name)) return obj;
        }
        return null;
    }

    pub fn computeReachableSet(self: *const Protocol, gpa: mem.Allocator, global_iface: []const u8, requested_version: u32) !ObjectSet {
        if (self.findObject(global_iface) == null) {
            return root.GenerateError.UnknownGlobalInterface;
        }

        var selected: ObjectSet = .{};
        var queue: std.ArrayList([]const u8) = .empty;
        defer queue.deinit(gpa);

        try selected.insert(gpa, global_iface);
        try queue.append(gpa, global_iface);

        var idx: usize = 0;
        while (idx < queue.items.len) : (idx += 1) {
            const current = queue.items[idx];
            const obj = self.findObject(current) orelse continue;

            for (obj.c2s_methods) |method| {
                if (method.since > requested_version) continue;
                if (method.returns_type.len > 0 and !selected.contains(method.returns_type)) {
                    if (self.findObject(method.returns_type) != null) {
                        try selected.insert(gpa, method.returns_type);
                        try queue.append(gpa, method.returns_type);
                    }
                }
                for (method.args) |arg| {
                    if (arg.interface.len == 0) continue;
                    if (selected.contains(arg.interface)) continue;
                    if (self.findObject(arg.interface) != null) {
                        try selected.insert(gpa, arg.interface);
                        try queue.append(gpa, arg.interface);
                    }
                }
            }

            for (obj.s2c_methods) |method| {
                if (method.since > requested_version) continue;
                if (method.returns_type.len > 0 and !selected.contains(method.returns_type)) {
                    if (self.findObject(method.returns_type) != null) {
                        try selected.insert(gpa, method.returns_type);
                        try queue.append(gpa, method.returns_type);
                    }
                }
                for (method.args) |arg| {
                    if (arg.interface.len == 0) continue;
                    if (selected.contains(arg.interface)) continue;
                    if (self.findObject(arg.interface) != null) {
                        try selected.insert(gpa, arg.interface);
                        try queue.append(gpa, arg.interface);
                    }
                }
            }
        }

        return selected;
    }
};

pub const ObjectSet = struct {
    map: std.StringHashMapUnmanaged(void) = .empty,

    pub fn contains(self: *const ObjectSet, name: []const u8) bool {
        return self.map.contains(name);
    }

    pub fn insert(self: *ObjectSet, gpa: mem.Allocator, name: []const u8) !void {
        try self.map.put(gpa, name, {});
    }
};

pub const Object = struct {
    name: []const u8,
    name_pascal: []const u8,
    name_camel: []const u8,
    version: u32,
    c2s_methods: []Method,
    s2c_methods: []Method,

    pub fn fromElement(elem: *const Node.Element, gpa: mem.Allocator) !Object {
        const name = elem.attributes.get("name") orelse return error.MissingObjectName;
        const version_str = elem.attributes.get("version") orelse return error.MissingObjectVersion;
        const version = try std.fmt.parseInt(u32, version_str, 10);

        var c2s_methods: std.ArrayList(Method) = .empty;
        var s2c_methods: std.ArrayList(Method) = .empty;

        var c2s_idx: u32 = 0;
        var s2c_idx: u32 = 0;
        for (elem.children) |child| {
            switch (child) {
                .element => |e| {
                    if (mem.eql(u8, e.name, "c2s")) {
                        try c2s_methods.append(gpa, try Method.fromElement(&e, c2s_idx, gpa));
                        c2s_idx += 1;
                    } else if (mem.eql(u8, e.name, "s2c")) {
                        try s2c_methods.append(gpa, try Method.fromElement(&e, s2c_idx, gpa));
                        s2c_idx += 1;
                    }
                },
                else => {},
            }
        }

        return .{
            .name = name,
            .name_pascal = try toPascalCase(name, gpa),
            .name_camel = try toCamelCase(name, gpa),
            .version = version,
            .c2s_methods = try c2s_methods.toOwnedSlice(gpa),
            .s2c_methods = try s2c_methods.toOwnedSlice(gpa),
        };
    }
};

pub const Method = struct {
    name: []const u8,
    name_pascal: []const u8,
    idx: u32,
    params: []const u8,
    returns_type: []const u8,
    since: u32,
    args: []Arg,
    is_destructor: bool,

    pub fn fromElement(elem: *const Node.Element, idx: u32, gpa: mem.Allocator) !Method {
        const name = elem.attributes.get("name") orelse return error.MissingMethodName;
        const is_destructor = if (elem.attributes.get("destructor")) |d| mem.eql(u8, d, "true") else false;

        const since_str = elem.attributes.get("since") orelse "0";
        const since = std.fmt.parseInt(u32, since_str, 10) catch 0;

        const params = try generateMethodParams(elem, gpa);

        var args: std.ArrayList(Arg) = .empty;
        var returns_type: []const u8 = "";
        for (elem.children) |child| {
            switch (child) {
                .element => |e| {
                    if (mem.eql(u8, e.name, "returns")) {
                        returns_type = e.attributes.get("iface") orelse "";
                    } else if (mem.eql(u8, e.name, "arg")) {
                        try args.append(gpa, try Arg.fromElement(&e, gpa));
                    }
                },
                else => {},
            }
        }

        return .{
            .name = name,
            .name_pascal = try toPascalCase(name, gpa),
            .idx = idx,
            .params = params,
            .returns_type = returns_type,
            .since = since,
            .args = try args.toOwnedSlice(gpa),
            .is_destructor = is_destructor,
        };
    }
};

pub const Arg = struct {
    name: []const u8,
    type_str: []const u8,
    interface: []const u8,
    is_array: bool,
    base_type: []const u8,
    zig_event_type: []const u8,
    zig_send_type: []const u8,
    zig_server_event_type: []const u8,
    zig_server_struct_type: []const u8,

    pub fn fromElement(elem: *const Node.Element, gpa: mem.Allocator) !Arg {
        const arg_name = elem.attributes.get("name") orelse return error.MissingArgName;
        const type_str = elem.attributes.get("type") orelse return error.MissingArgType;
        const interface = elem.attributes.get("interface") orelse "";

        const is_array = mem.startsWith(u8, type_str, "array ");
        const base_type = if (is_array) type_str[6..] else type_str;

        return .{
            .name = arg_name,
            .type_str = type_str,
            .interface = interface,
            .is_array = is_array,
            .base_type = base_type,
            .zig_event_type = try computeEventArgType(gpa, base_type, interface, is_array),
            .zig_send_type = try computeSendArgType(gpa, base_type, is_array, interface),
            .zig_server_event_type = try computeServerEventArgType(gpa, base_type, is_array),
            .zig_server_struct_type = try computeServerStructType(gpa, base_type, interface, is_array),
        };
    }
};

pub const Enum = struct {
    name: []const u8,
    name_pascal: []const u8,
    values: []EnumValue,

    pub fn fromElement(elem: *const Node.Element, gpa: mem.Allocator) !Enum {
        const name = elem.attributes.get("name") orelse return error.MissingEnumName;

        var values: std.ArrayList(EnumValue) = .empty;
        for (elem.children) |child| {
            switch (child) {
                .element => |e| {
                    if (mem.eql(u8, e.name, "value")) {
                        const value_name = e.attributes.get("name") orelse return error.MissingEnumValueName;
                        const idx_str = e.attributes.get("idx") orelse return error.MissingEnumValueIdx;
                        const idx = try std.fmt.parseInt(u32, idx_str, 10);

                        try values.append(gpa, .{
                            .name = value_name,
                            .idx = idx,
                        });
                    }
                },
                else => {},
            }
        }

        return .{
            .name = name,
            .name_pascal = try toPascalCase(name, gpa),
            .values = try values.toOwnedSlice(gpa),
        };
    }
};

pub const EnumValue = struct {
    name: []const u8,
    idx: u32,
};

fn generateMethodParams(method: *const Node.Element, gpa: mem.Allocator) ![]const u8 {
    var params: std.ArrayList(u8) = .empty;

    for (method.children) |child| {
        switch (child) {
            .element => |e| {
                if (mem.eql(u8, e.name, "arg")) {
                    const type_attr = e.attributes.get("type") orelse return error.MissingType;
                    const param_bytes = try parseType(type_attr, gpa);
                    try params.appendSlice(gpa, param_bytes);
                }
            },
            else => {},
        }
    }

    return try params.toOwnedSlice(gpa);
}

fn parseType(type_str: []const u8, gpa: mem.Allocator) ![]const u8 {
    if (mem.startsWith(u8, type_str, "array ")) {
        const element_type = type_str[6..];
        const element_magic = try parseType(element_type, gpa);
        var result: std.ArrayList(u8) = .empty;
        try result.append(gpa, @intFromEnum(MessageMagic.type_array));
        try result.appendSlice(gpa, element_magic);
        return try result.toOwnedSlice(gpa);
    } else if (mem.eql(u8, type_str, "varchar")) {
        var result: std.ArrayList(u8) = .empty;
        try result.append(gpa, @intFromEnum(MessageMagic.type_varchar));
        return try result.toOwnedSlice(gpa);
    } else if (mem.eql(u8, type_str, "uint")) {
        var result: std.ArrayList(u8) = .empty;
        try result.append(gpa, @intFromEnum(MessageMagic.type_uint));
        return try result.toOwnedSlice(gpa);
    } else if (mem.eql(u8, type_str, "int")) {
        var result: std.ArrayList(u8) = .empty;
        try result.append(gpa, @intFromEnum(MessageMagic.type_int));
        return try result.toOwnedSlice(gpa);
    } else if (mem.eql(u8, type_str, "fd")) {
        var result: std.ArrayList(u8) = .empty;
        try result.append(gpa, @intFromEnum(MessageMagic.type_fd));
        return try result.toOwnedSlice(gpa);
    } else if (mem.eql(u8, type_str, "enum")) {
        var result: std.ArrayList(u8) = .empty;
        try result.append(gpa, @intFromEnum(MessageMagic.type_uint));
        return try result.toOwnedSlice(gpa);
    } else {
        return error.UnknownType;
    }
}

fn computeEventArgType(gpa: mem.Allocator, base_type: []const u8, interface: []const u8, is_array: bool) ![]const u8 {
    const arr = if (is_array) "[]const " else "";
    if (mem.eql(u8, base_type, "varchar")) {
        return fmt.allocPrint(gpa, "{s}[*:0]const u8", .{arr});
    } else if (mem.eql(u8, base_type, "uint")) {
        return fmt.allocPrint(gpa, "{s}u32", .{arr});
    } else if (mem.eql(u8, base_type, "int") or
        mem.eql(u8, base_type, "fd"))
    {
        return fmt.allocPrint(gpa, "{s}i32", .{arr});
    } else if (mem.eql(u8, base_type, "enum")) {
        const enum_pascal = try toPascalCase(interface, gpa);
        return fmt.allocPrint(gpa, "{s}spec.{s}", .{ arr, enum_pascal });
    }

    unreachable;
}

fn computeServerStructType(gpa: mem.Allocator, base_type: []const u8, interface: []const u8, is_array: bool) ![]const u8 {
    const arr = if (is_array) "[]const " else "";
    if (mem.eql(u8, base_type, "varchar")) {
        return fmt.allocPrint(gpa, "{s}[*:0]const u8", .{arr});
    } else if (mem.eql(u8, base_type, "uint")) {
        return fmt.allocPrint(gpa, "{s}u32", .{arr});
    } else if (mem.eql(u8, base_type, "int") or (mem.eql(u8, base_type, "fd"))) {
        return fmt.allocPrint(gpa, "{s}i32", .{arr});
    } else if (mem.eql(u8, base_type, "enum")) {
        const enum_pascal = try toPascalCase(interface, gpa);
        return fmt.allocPrint(gpa, "{s}spec.{s}", .{ arr, enum_pascal });
    }

    unreachable;
}

fn computeSendArgType(gpa: mem.Allocator, base_type: []const u8, is_array: bool, interface: []const u8) ![]const u8 {
    const arr = if (is_array) "[]const " else "";
    if (mem.eql(u8, base_type, "varchar")) {
        return fmt.allocPrint(gpa, "{s}[:0]const u8", .{arr});
    } else if (mem.eql(u8, base_type, "uint")) {
        return fmt.allocPrint(gpa, "{s}u32", .{arr});
    } else if (mem.eql(u8, base_type, "int") or
        mem.eql(u8, base_type, "fd"))
    {
        return fmt.allocPrint(gpa, "{s}i32", .{arr});
    } else if (mem.eql(u8, base_type, "enum")) {
        const enum_pascal = try toPascalCase(interface, gpa);
        return fmt.allocPrint(gpa, "{s}spec.{s}", .{ arr, enum_pascal });
    }

    unreachable;
}

fn computeServerEventArgType(gpa: mem.Allocator, base_type: []const u8, is_array: bool) ![]const u8 {
    const arr = if (is_array) "[*]const " else "";
    if (mem.eql(u8, base_type, "varchar")) {
        return fmt.allocPrint(gpa, "{s}[*:0]const u8", .{arr});
    } else if (mem.eql(u8, base_type, "uint")) {
        return fmt.allocPrint(gpa, "{s}u32", .{arr});
    } else if (mem.eql(u8, base_type, "int") or
        mem.eql(u8, base_type, "fd") or
        mem.eql(u8, base_type, "enum"))
    {
        return fmt.allocPrint(gpa, "{s}i32", .{arr});
    }

    unreachable;
}

pub fn toPascalCase(name: []const u8, gpa: mem.Allocator) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var capitalize_next = true;

    for (name) |c| {
        if (c == '_') {
            capitalize_next = true;
        } else {
            if (capitalize_next) {
                try result.append(gpa, std.ascii.toUpper(c));
                capitalize_next = false;
            } else {
                try result.append(gpa, c);
            }
        }
    }

    return try result.toOwnedSlice(gpa);
}

pub fn toCamelCase(name: []const u8, gpa: mem.Allocator) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var capitalize_next = false;

    for (name) |c| {
        if (c == '_') {
            capitalize_next = true;
        } else {
            if (capitalize_next) {
                try result.append(gpa, std.ascii.toUpper(c));
                capitalize_next = false;
            } else {
                try result.append(gpa, c);
            }
        }
    }

    return try result.toOwnedSlice(gpa);
}

fn extractTextContent(elem: *const Node.Element, gpa: mem.Allocator) ![]const u8 {
    var text_parts: std.ArrayList([]const u8) = .empty;
    defer {
        for (text_parts.items) |part| {
            gpa.free(part);
        }
        text_parts.deinit(gpa);
    }

    for (elem.children) |child| {
        switch (child) {
            .text => |t| {
                if (mem.trim(u8, t, " \t\n\r").len > 0) {
                    try text_parts.append(gpa, try gpa.dupe(u8, mem.trim(u8, t, " \t\n\r")));
                }
            },
            else => {},
        }
    }

    if (text_parts.items.len == 0) {
        return "";
    }

    if (text_parts.items.len == 1) {
        const result = text_parts.items[0];
        text_parts.items.len = 0; // Prevent free in defer
        return result;
    }

    var total_len: usize = 0;
    for (text_parts.items) |part| {
        total_len += part.len;
    }

    var result = try gpa.alloc(u8, total_len);
    var offset: usize = 0;
    for (text_parts.items) |part| {
        @memcpy(result[offset .. offset + part.len], part);
        offset += part.len;
    }

    return result;
}
