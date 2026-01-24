const std = @import("std");
const mem = std.mem;
const xml = @import("xml");

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

const types = struct {
    pub const Method = struct {
        idx: u32,
        params: []const u8,
    };
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

pub fn generateClientCode(gpa: mem.Allocator, doc: *const Document) ![]const u8 {
    const protocol_info = try extractProtocolInfo(doc, gpa);

    var output: std.Io.Writer.Allocating = .init(gpa);
    var writer = &output.writer;

    try writer.print(
        \\const std = @import("std");
        \\
        \\const hyprwire = @import("hyprwire");
        \\const types = hyprwire.types;
        \\const client = types.client;
        \\const spec = hyprwire.proto.{s}.spec;
        \\
        \\
    , .{protocol_info.name});

    for (protocol_info.objects, 0..) |obj_info, obj_idx| {
        const struct_name = try toPascalCase(obj_info.name, gpa);
        const camel_name = try toCamelCase(obj_info.name, gpa);

        for (obj_info.s2c_methods, 0..) |method, idx| {
            try writeClientMethodHandler(writer, gpa, struct_name, camel_name, method, idx);
        }

        try writeClientObjectStruct(writer, gpa, struct_name, camel_name, obj_info, obj_idx > 0, obj_idx > 0);
    }

    const protocol_struct_name = try toPascalCase(protocol_info.name, gpa);
    try writer.print(
        \\pub const {s}Impl = struct {{
        \\    version: u32,
        \\
        \\    const Self = @This();
        \\
        \\    pub fn init(version: u32) Self {{
        \\        return .{{ .version = version }};
        \\    }}
        \\
        \\    pub fn protocol(self: *Self) types.ProtocolSpec {{
        \\        _ = self;
        \\        return types.ProtocolSpec.from(&spec.protocol);
        \\    }}
        \\
        \\    pub fn implementation(
        \\        self: *Self,
        \\        gpa: std.mem.Allocator,
        \\    ) ![]*client.ObjectImplementation {{
        \\        const impls = try gpa.alloc(*client.ObjectImplementation, {});
        \\        errdefer gpa.free(impls);
        \\
        \\
    , .{ protocol_struct_name, protocol_info.objects.len });

    for (protocol_info.objects, 0..) |obj_info, idx| {
        try writer.print(
            \\        impls[{}] = try gpa.create(client.ObjectImplementation);
            \\        errdefer gpa.destroy(impls[{}]);
            \\        impls[{}].* = .{{
            \\            .object_name = "{s}",
            \\            .version = self.version,
            \\        }};
            \\
        , .{ idx, idx, idx, obj_info.name });
        if (idx < protocol_info.objects.len - 1) {
            try writer.print("\n", .{});
        }
    }

    try writer.print(
        \\
        \\        return impls;
        \\    }}
        \\}};
    , .{});

    return output.toOwnedSlice();
}

fn writeClientMethodHandler(writer: anytype, gpa: mem.Allocator, struct_name: []const u8, camel_name: []const u8, method: MethodInfo, idx: usize) !void {
    try writer.print("fn {s}_method{}(r: *types.Object", .{ camel_name, idx });

    for (method.args) |arg| {
        const zig_type = try getEventArgType(arg, gpa);
        try writer.print(", {s}: {s}", .{ arg.name, zig_type });
    }

    try writer.print(
        \\) callconv(.c) void {{
        \\    const object: *{s}Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
        \\    defer _ = object.arena.reset(.retain_capacity);
        \\    var buffer: [32_768]u8 = undefined;
        \\    var fba = std.heap.FixedBufferAllocator.init(&buffer);
        \\    var fallback_allocator = hyprwire.FallbackAllocator{{
        \\        .fba = &fba,
        \\        .fallback = fba.allocator(),
        \\        .fixed = object.arena.allocator(),
        \\    }};
        \\    object.listener.vtable.{s}Listener(
        \\        object.listener.ptr,
        \\        fallback_allocator.allocator(),
        \\        .{{
        \\            .{s} = .{{
    , .{ struct_name, camel_name, method.name });

    for (method.args) |arg| {
        try writer.print(
            \\
            \\                .{s} = {s},
        , .{ arg.name, arg.name });
    }

    try writer.print(
        \\
        \\            }},
        \\        }},
        \\    );
        \\}}
        \\
        \\
    , .{});
}

fn writeClientObjectStruct(writer: anytype, gpa: mem.Allocator, struct_name: []const u8, camel_name: []const u8, obj_info: ObjectInfo, use_short_init: bool, generate_set_send_message: bool) !void {
    try writer.print("pub const {s}Object = struct {{\n", .{struct_name});

    try writer.print("    pub const Event = union(enum) {{\n", .{});
    for (obj_info.s2c_methods) |method| {
        try writer.print("        {s}: struct {{\n", .{method.name});
        for (method.args) |arg| {
            const zig_type = try getEventArgType(arg, gpa);
            try writer.print("            {s}: {s},\n", .{ arg.name, zig_type });
        }
        try writer.print("        }},\n", .{});
    }
    try writer.print("    }};\n\n", .{});

    try writer.print(
        \\    pub const Listener = hyprwire.Trait(.{{
        \\        .{s}Listener = fn (std.mem.Allocator, Event) void,
        \\    }}, null);
        \\
        \\    object: *types.Object,
        \\    listener: Listener,
        \\    arena: std.heap.ArenaAllocator,
        \\
        \\    const Self = @This();
        \\
    , .{camel_name});

    if (use_short_init) {
        try writer.print(
            \\
            \\    pub fn init(gpa: std.mem.Allocator, listener: Listener, object: *types.Object) !*Self {{
            \\        const self = try gpa.create(Self);
            \\        self.* = .{{
            \\            .object = object,
            \\            .listener = listener,
            \\            .arena = std.heap.ArenaAllocator.init(gpa),
            \\        }};
            \\
            \\        object.vtable.setData(object.ptr, self);
            \\
        , .{});
    } else {
        try writer.print(
            \\
            \\    pub fn init(gpa: std.mem.Allocator, listener: Listener, object: *types.Object) !*Self {{
            \\        const self = try gpa.create(Self);
            \\        self.* = Self{{
            \\            .listener = listener,
            \\            .object = object,
            \\            .arena = std.heap.ArenaAllocator.init(gpa),
            \\        }};
            \\
            \\        object.vtable.setData(object.ptr, self);
            \\
        , .{});
    }

    for (obj_info.s2c_methods, 0..) |_, idx| {
        try writer.print("        try object.vtable.listen(object.ptr, gpa, {}, @ptrCast(&{s}_method{}));\n", .{ idx, camel_name, idx });
    }

    try writer.print(
        \\
        \\        return self;
        \\    }}
        \\
        \\    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {{
        \\        gpa.destroy(self);
        \\    }}
        \\
    , .{});

    for (obj_info.c2s_methods) |method| {
        try writeClientSendMethod(writer, gpa, method);
    }

    if (generate_set_send_message) {
        for (obj_info.s2c_methods) |method| {
            if (method.args.len == 1 and mem.eql(u8, method.args[0].type_str, "varchar")) {
                try writer.print(
                    \\
                    \\    pub fn setSendMessage(self: *Self, callback: *const fn ([*:0]const u8) void) void {{
                    \\        self.listener.send_message = callback;
                    \\    }}
                    \\
                , .{});
                break;
            }
        }
    }

    try writer.print(
        \\
        \\    pub fn dispatch(
        \\        self: *Self,
        \\        opcode: u16,
        \\        args: anytype,
        \\    ) void {{
        \\        switch (opcode) {{
    , .{});

    for (obj_info.s2c_methods, 0..) |method, idx| {
        try writer.print(
            \\
            \\            {} => if (self.listener.{s}) |cb|
            \\                cb(self, args[0]),
        , .{ idx, method.name });
    }

    try writer.print(
        \\
        \\            else => {{}},
        \\        }}
        \\    }}
        \\}};
        \\
        \\
    , .{});
}

fn writeClientSendMethod(writer: anytype, gpa: mem.Allocator, method: MethodInfo) !void {
    const method_pascal = try toPascalCase(method.name, gpa);

    if (method.returns_type.len > 0) {
        try writer.print(
            \\
            \\    pub fn send{s}(self: *Self, gpa: std.mem.Allocator) ?types.Object {{
            \\        var args = types.Args.init(gpa, .{{}}) catch return null;
            \\        defer args.deinit(gpa);
            \\        const id = self.object.vtable.call(self.object.ptr, gpa, {}, &args) catch return null;
            \\        if (self.object.vtable.clientSock(self.object.ptr)) |sock| {{
            \\            return sock.objectForId(id);
            \\        }}
            \\
            \\        return null;
            \\    }}
            \\
        , .{ method_pascal, method.idx });
    } else if (method.is_destructor) {
        try writer.print(
            \\
            \\    pub fn send{s}(self: *Self, gpa: std.mem.Allocator) !void {{
            \\        var args = try types.Args.init(gpa, .{{}});
            \\        defer args.deinit(gpa);
            \\        _ = try self.object.vtable.call(self.object.ptr, gpa, {}, &args);
            \\        self.object.destroy();
            \\    }}
            \\
        , .{ method_pascal, method.idx });
    } else if (method.args.len == 0) {
        try writer.print(
            \\
            \\    pub fn send{s}(self: *Self, gpa: std.mem.Allocator) !void {{
            \\        var args = try types.Args.init(gpa, .{{}});
            \\        defer args.deinit(gpa);
            \\        _ = try self.object.vtable.call(self.object.ptr, gpa, {}, &args);
            \\    }}
            \\
        , .{ method_pascal, method.idx });
    } else {
        try writer.print("\n    pub fn send{s}(self: *Self, gpa: std.mem.Allocator", .{method_pascal});

        for (method.args) |arg| {
            const zig_type = try getSendArgType(arg, gpa);
            try writer.print(", {s}: {s}", .{ arg.name, zig_type });
        }

        try writer.print(") !void {{\n        var args = try types.Args.init(gpa, .{{", .{});

        for (method.args) |arg| {
            try writer.print("{s}", .{arg.name});
        }

        try writer.print(
            \\}});
            \\        defer args.deinit(gpa);
            \\        _ = try self.object.vtable.call(self.object.ptr, gpa, {}, &args);
            \\    }}
            \\
        , .{method.idx});
    }
}

fn getEventArgType(arg: ArgInfo, gpa: mem.Allocator) ![]const u8 {
    if (arg.is_array) {
        if (mem.eql(u8, arg.base_type, "uint")) {
            return "[*:0]u32";
        } else if (mem.eql(u8, arg.base_type, "varchar")) {
            return "[*][*:0]const u8";
        }
    }

    if (mem.eql(u8, arg.type_str, "varchar")) {
        return "[*:0]const u8";
    } else if (mem.eql(u8, arg.type_str, "uint")) {
        return "u32";
    } else if (mem.eql(u8, arg.type_str, "int")) {
        return "i32";
    } else if (mem.eql(u8, arg.type_str, "fd")) {
        return "i32";
    } else if (mem.eql(u8, arg.type_str, "enum")) {
        const enum_pascal = try toPascalCase(arg.interface, gpa);
        return try std.fmt.allocPrint(gpa, "spec.{s}", .{enum_pascal});
    }

    return "void";
}

fn getSendArgType(arg: ArgInfo, gpa: mem.Allocator) ![]const u8 {
    if (arg.is_array) {
        if (mem.eql(u8, arg.base_type, "uint")) {
            return "[]const u32";
        } else if (mem.eql(u8, arg.base_type, "varchar")) {
            return "[]const [:0]const u8";
        }
    }

    if (mem.eql(u8, arg.type_str, "varchar")) {
        return "[:0]const u8";
    } else if (mem.eql(u8, arg.type_str, "uint")) {
        return "u32";
    } else if (mem.eql(u8, arg.type_str, "int")) {
        return "i32";
    } else if (mem.eql(u8, arg.type_str, "fd")) {
        return "i32";
    } else if (mem.eql(u8, arg.type_str, "enum")) {
        const enum_pascal = try toPascalCase(arg.interface, gpa);
        return try std.fmt.allocPrint(gpa, "spec.{s}", .{enum_pascal});
    }

    return "void";
}

pub fn generateServerCode(gpa: mem.Allocator, doc: *const Document) ![]const u8 {
    const protocol_info = try extractProtocolInfo(doc, gpa);

    var output: std.Io.Writer.Allocating = .init(gpa);
    var writer = &output.writer;

    try writer.print(
        \\const std = @import("std");
        \\
        \\const hyprwire = @import("hyprwire");
        \\const types = hyprwire.types;
        \\const server = types.server;
        \\const spec = hyprwire.proto.{s}.spec;
        \\
    , .{protocol_info.name});

    for (protocol_info.objects, 0..) |obj_info, obj_idx| {
        const struct_name = try toPascalCase(obj_info.name, gpa);
        const camel_name = try toCamelCase(obj_info.name, gpa);

        for (obj_info.c2s_methods, 0..) |method, idx| {
            try writeServerMethodHandler(writer, gpa, struct_name, camel_name, method, idx);
        }

        const is_last = obj_idx == protocol_info.objects.len - 1;
        try writeServerObjectStruct(writer, gpa, struct_name, camel_name, obj_info, is_last);
    }

    const protocol_struct_name = try toPascalCase(protocol_info.name, gpa);

    try writer.print(
        \\pub const {s}Listener = hyprwire.Trait(.{{
        \\    .bind = fn (*types.Object) void,
        \\}}, null);
        \\
        \\pub const {s}Impl = struct {{
        \\    version: u32,
        \\    listener: {s}Listener,
        \\
        \\    const Self = @This();
        \\
        \\    pub fn init(
        \\        version: u32,
        \\        listener: {s}Listener,
        \\    ) Self {{
        \\        return .{{
        \\            .version = version,
        \\            .listener = listener,
        \\        }};
        \\    }}
        \\
        \\    pub fn protocol(_: *Self) types.ProtocolSpec {{
        \\        return types.ProtocolSpec.from(&spec.{s}ProtocolSpec{{}});
        \\    }}
        \\
        \\    pub fn implementation(
        \\        self: *Self,
        \\        gpa: std.mem.Allocator,
        \\    ) ![]*server.ObjectImplementation {{
        \\        const impls = try gpa.alloc(*server.ObjectImplementation, {});
        \\        errdefer gpa.free(impls);
        \\
        \\
    , .{ protocol_struct_name, protocol_struct_name, protocol_struct_name, protocol_struct_name, protocol_struct_name, protocol_info.objects.len });

    for (protocol_info.objects, 0..) |obj_info, idx| {
        const is_first = idx == 0;
        try writer.print(
            \\        impls[{}] = try gpa.create(server.ObjectImplementation);
            \\        errdefer gpa.destroy(impls[{}]);
            \\        impls[{}].* = .{{
            \\            .context = self.listener.ptr,
            \\            .object_name = "{s}",
            \\            .version = self.version,
        , .{ idx, idx, idx, obj_info.name });

        if (is_first) {
            try writer.print(
                \\
                \\            .onBind = self.listener.vtable.bind,
                \\        }};
                \\
            , .{});
        } else {
            try writer.print(
                \\
                \\        }};
                \\
            , .{});
        }
        if (idx < protocol_info.objects.len - 1) {
            try writer.print("\n", .{});
        }
    }

    try writer.print(
        \\
        \\        return impls;
        \\    }}
        \\}};
    , .{});

    return output.toOwnedSlice();
}

fn writeServerMethodHandler(writer: anytype, gpa: mem.Allocator, struct_name: []const u8, camel_name: []const u8, method: MethodInfo, idx: usize) !void {
    try writer.print("\nfn {s}_method{}(r: *types.Object", .{ camel_name, idx });

    for (method.args) |arg| {
        if (arg.is_array and mem.eql(u8, arg.base_type, "varchar")) {
            try writer.print(", {s}: [*][*:0]const u8, {s}_len: u32", .{ arg.name, arg.name });
        } else if (mem.eql(u8, arg.type_str, "enum")) {
            try writer.print(", value: i32", .{});
        } else if (mem.eql(u8, arg.type_str, "fd")) {
            try writer.print(", fd: i32", .{});
        } else {
            const zig_type = try getServerEventArgType(arg, gpa);
            if (method.returns_type.len > 0) {
                try writer.print(", seq: u32", .{});
            } else {
                try writer.print(", {s}: {s}", .{ arg.name, zig_type });
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
        \\        .fallback = fba.allocator(),
        \\        .fixed = object.arena.allocator(),
        \\    }};
        \\    object.listener.vtable.{s}Listener(
        \\        object.listener.ptr,
        \\        fallback_allocator.allocator(),
    , .{ struct_name, camel_name });

    if (method.args.len == 0 and method.returns_type.len == 0) {
        try writer.print(
            \\
            \\        .{{ .{s} = .{{}} }},
            \\    );
            \\}}
            \\
        , .{method.name});
        return;
    }

    try writer.print(
        \\
        \\        .{{ .{s} = .{{
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
            if (arg.is_array and mem.eql(u8, arg.base_type, "varchar")) {
                try writer.print(
                    \\
                    \\            .{s} = fallback_allocator.allocator().dupe([*:0]const u8, {s}[0..{s}_len]) catch return,
                , .{ arg.name, arg.name, arg.name });
            } else if (mem.eql(u8, arg.type_str, "enum")) {
                try writer.print(
                    \\
                    \\            .{s} = @enumFromInt(value),
                , .{arg.name});
            } else if (mem.eql(u8, arg.type_str, "fd")) {
                try writer.print(
                    \\
                    \\            .{s} = fd,
                , .{arg.name});
            } else if (method.returns_type.len > 0) {
                try writer.print(
                    \\
                    \\            .seq = seq,
                , .{});
            } else {
                try writer.print(
                    \\
                    \\            .{s} = {s},
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

fn writeServerObjectStruct(writer: anytype, gpa: mem.Allocator, struct_name: []const u8, camel_name: []const u8, obj_info: ObjectInfo, is_last: bool) !void {
    const is_first_object = mem.eql(u8, obj_info.name, "my_manager_v1");

    try writer.print("\npub const {s}Object = struct {{\n", .{struct_name});

    try writer.print("    pub const Event = union(enum) {{\n", .{});
    for (obj_info.c2s_methods) |method| {
        if (method.args.len == 0 and method.returns_type.len == 0) {
            try writer.print("        {s}: struct {{}},\n", .{method.name});
        } else {
            try writer.print("        {s}: struct {{\n", .{method.name});
            if (method.returns_type.len > 0) {
                try writer.print("            seq: u32,\n", .{});
            } else {
                for (method.args) |arg| {
                    const zig_type = try getServerEventStructType(arg, gpa);
                    try writer.print("            {s}: {s},\n", .{ arg.name, zig_type });
                }
            }
            try writer.print("        }},\n", .{});
        }
    }
    try writer.print("    }};\n", .{});

    try writer.print(
        \\
        \\    pub const Listener = hyprwire.Trait(.{{
        \\        .{s}Listener = fn (std.mem.Allocator, Event) void,
        \\    }}, null);
        \\
        \\    object: *types.Object,
        \\    listener: Listener,
        \\    arena: std.heap.ArenaAllocator,
        \\
        \\    const Self = @This();
        \\
        \\    pub fn init(gpa: std.mem.Allocator, listener: Listener, object: *types.Object) !*Self {{
        \\        const self = try gpa.create(Self);
        \\        self.* = .{{
    , .{camel_name});

    if (is_first_object) {
        try writer.print(
            \\
            \\            .listener = listener,
            \\            .object = object,
            \\            .arena = std.heap.ArenaAllocator.init(gpa),
            \\        }};
            \\
            \\        object.vtable.setData(object.ptr, self);
            \\
        , .{});
    } else {
        try writer.print(
            \\
            \\            .object = object,
            \\            .listener = listener,
            \\            .arena = std.heap.ArenaAllocator.init(gpa),
            \\        }};
            \\
            \\        object.vtable.setData(object.ptr, self);
            \\
        , .{});
    }

    try writer.print("\n", .{});
    for (obj_info.c2s_methods, 0..) |_, idx| {
        try writer.print("        try object.vtable.listen(object.ptr, gpa, {}, @ptrCast(&{s}_method{}));\n", .{ idx, camel_name, idx });
    }

    if (is_first_object) {
        try writer.print(
            \\
            \\        return self;
            \\    }}
            \\    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {{
            \\        self.arena.deinit();
            \\        gpa.destroy(self);
            \\    }}
            \\
            \\    pub fn getObject(self: *Self) *types.Object {{
            \\        return self.object;
            \\    }}
            \\
            \\    pub fn err(self: *Self, code: u32, message: []const u8) void {{
            \\        self.object.vtable.err(self.object.ptr, code, message);
            \\    }}
            \\
            \\    pub fn setOnDeinit(self: *Self, @"fn": *const fn () void) void {{
            \\        self.object.vtable.setOnDeinit(self.object.ptr, @"fn");
            \\    }}
            \\
        , .{});
    } else {
        try writer.print(
            \\        return self;
            \\    }}
            \\
            \\    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {{
            \\        self.arena.deinit();
            \\        gpa.destroy(self);
            \\    }}
            \\
            \\    pub fn setOnDeinit(self: *Self, @"fn": *const fn (*Self) void) void {{
            \\        self.object.vtable.setOnDeinit(self.object.ptr, @"fn");
            \\    }}
            \\
            \\    pub fn err(self: *Self, gpa: std.mem.Allocator, code: u32, message: [:0]const u8) !void {{
            \\        try self.object.vtable.err(self.object.ptr, gpa, code, message);
            \\    }}
            \\
        , .{});
    }

    for (obj_info.s2c_methods) |method| {
        try writeServerSendMethod(writer, gpa, method);
    }

    if (is_last) {
        try writer.print("}};\n\n", .{});
    } else {
        try writer.print("}};\n", .{});
    }
}

fn writeServerSendMethod(writer: anytype, gpa: mem.Allocator, method: MethodInfo) !void {
    const method_pascal = try toPascalCase(method.name, gpa);

    if (method.args.len == 0) {
        try writer.print(
            \\
            \\    pub fn send{s}(self: *Self, gpa: std.mem.Allocator) !void {{
            \\        var args = try types.Args.init(gpa, .{{}});
            \\        defer args.deinit(gpa);
            \\        _ = try self.object.vtable.call(self.object.ptr, gpa, {}, &args);
            \\    }}
        , .{ method_pascal, method.idx });
    } else {
        try writer.print("\n    pub fn send{s}(self: *Self, gpa: std.mem.Allocator", .{method_pascal});

        for (method.args) |arg| {
            const zig_type = try getSendArgType(arg, gpa);
            try writer.print(", {s}: {s}", .{ arg.name, zig_type });
        }

        try writer.print(") !void {{\n        var args = try types.Args.init(gpa, .{{", .{});

        for (method.args) |arg| {
            try writer.print("{s}", .{arg.name});
        }

        try writer.print(
            \\}});
            \\        defer args.deinit(gpa);
            \\        _ = try self.object.vtable.call(self.object.ptr, gpa, {}, &args);
            \\    }}
            \\
        , .{method.idx});
    }
}

fn getServerEventArgType(arg: ArgInfo, gpa: mem.Allocator) ![]const u8 {
    _ = gpa;
    if (arg.is_array) {
        if (mem.eql(u8, arg.base_type, "uint")) {
            return "[*:0]u32";
        } else if (mem.eql(u8, arg.base_type, "varchar")) {
            return "[*][*:0]const u8";
        }
    }

    if (mem.eql(u8, arg.type_str, "varchar")) {
        return "[*:0]const u8";
    } else if (mem.eql(u8, arg.type_str, "uint")) {
        return "u32";
    } else if (mem.eql(u8, arg.type_str, "int")) {
        return "i32";
    } else if (mem.eql(u8, arg.type_str, "fd")) {
        return "i32";
    } else if (mem.eql(u8, arg.type_str, "enum")) {
        return "i32";
    }

    return "void";
}

fn getServerEventStructType(arg: ArgInfo, gpa: mem.Allocator) ![]const u8 {
    if (arg.is_array) {
        if (mem.eql(u8, arg.base_type, "uint")) {
            return "[*:0]u32";
        } else if (mem.eql(u8, arg.base_type, "varchar")) {
            return "[][*:0]const u8";
        }
    }

    if (mem.eql(u8, arg.type_str, "varchar")) {
        return "[*:0]const u8";
    } else if (mem.eql(u8, arg.type_str, "uint")) {
        return "u32";
    } else if (mem.eql(u8, arg.type_str, "int")) {
        return "i32";
    } else if (mem.eql(u8, arg.type_str, "fd")) {
        return "i32";
    } else if (mem.eql(u8, arg.type_str, "enum")) {
        const enum_pascal = try toPascalCase(arg.interface, gpa);
        return try std.fmt.allocPrint(gpa, "spec.{s}", .{enum_pascal});
    }

    return "void";
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

fn hasReturns(method: *const Node.Element) bool {
    for (method.children) |child| {
        switch (child) {
            .element => |e| if (mem.eql(u8, e.name, "returns")) return true,
            else => {},
        }
    }
    return false;
}

const ProtocolInfo = struct {
    name: []const u8,
    version: u32,
    objects: []ObjectInfo,
    enums: []EnumInfo,
};

const ObjectInfo = struct {
    name: []const u8,
    version: u32,
    c2s_methods: []MethodInfo,
    s2c_methods: []MethodInfo,
};

const ArgInfo = struct {
    name: []const u8,
    type_str: []const u8,
    interface: []const u8,
    is_array: bool,
    base_type: []const u8,
};

const MethodInfo = struct {
    name: []const u8,
    idx: u32,
    params: []const u8,
    returns_type: []const u8,
    since: u32,
    args: []ArgInfo,
    is_destructor: bool,
};

const EnumInfo = struct {
    name: []const u8,
    values: []EnumValue,
};

const EnumValue = struct {
    name: []const u8,
    idx: u32,
};

fn extractProtocolInfo(doc: *const Document, gpa: mem.Allocator) !ProtocolInfo {
    const protocol_elem = findProtocolElement(doc) orelse return error.MissingProtocol;

    const name = protocol_elem.attributes.get("name") orelse return error.MissingProtocolName;
    const version_str = protocol_elem.attributes.get("version") orelse return error.MissingProtocolVersion;
    const version = try std.fmt.parseInt(u32, version_str, 10);

    var objects: std.ArrayList(ObjectInfo) = .empty;
    var enums: std.ArrayList(EnumInfo) = .empty;

    for (protocol_elem.children) |child| {
        switch (child) {
            .element => |e| {
                if (mem.eql(u8, e.name, "object")) {
                    const obj_info = try extractObjectInfo(&e, gpa);
                    try objects.append(gpa, obj_info);
                } else if (mem.eql(u8, e.name, "enum")) {
                    const enum_info = try extractEnumInfo(&e, gpa);
                    try enums.append(gpa, enum_info);
                }
            },
            else => {},
        }
    }

    return .{
        .name = name,
        .version = version,
        .objects = try objects.toOwnedSlice(gpa),
        .enums = try enums.toOwnedSlice(gpa),
    };
}

fn extractObjectInfo(obj_elem: *const Node.Element, gpa: mem.Allocator) !ObjectInfo {
    const name = obj_elem.attributes.get("name") orelse return error.MissingObjectName;
    const version_str = obj_elem.attributes.get("version") orelse return error.MissingObjectVersion;
    const version = try std.fmt.parseInt(u32, version_str, 10);

    var c2s_methods: std.ArrayList(MethodInfo) = .empty;
    var s2c_methods: std.ArrayList(MethodInfo) = .empty;

    var c2s_idx: u32 = 0;
    var s2c_idx: u32 = 0;
    for (obj_elem.children) |child| {
        switch (child) {
            .element => |e| {
                if (mem.eql(u8, e.name, "c2s")) {
                    const method_info = try extractMethodInfo(&e, c2s_idx, gpa);
                    try c2s_methods.append(gpa, method_info);
                    c2s_idx += 1;
                } else if (mem.eql(u8, e.name, "s2c")) {
                    const method_info = try extractMethodInfo(&e, s2c_idx, gpa);
                    try s2c_methods.append(gpa, method_info);
                    s2c_idx += 1;
                }
            },
            else => {},
        }
    }

    return .{
        .name = name,
        .version = version,
        .c2s_methods = try c2s_methods.toOwnedSlice(gpa),
        .s2c_methods = try s2c_methods.toOwnedSlice(gpa),
    };
}

fn extractMethodInfo(method_elem: *const Node.Element, idx: u32, gpa: mem.Allocator) !MethodInfo {
    const name = method_elem.attributes.get("name") orelse return error.MissingMethodName;
    const is_destructor = if (method_elem.attributes.get("destructor")) |d| mem.eql(u8, d, "true") else false;

    const params = try generateMethodParams(method_elem, gpa);

    var args: std.ArrayList(ArgInfo) = .empty;
    var returns_type: []const u8 = "";
    for (method_elem.children) |child| {
        switch (child) {
            .element => |e| {
                if (mem.eql(u8, e.name, "returns")) {
                    returns_type = e.attributes.get("iface") orelse "";
                } else if (mem.eql(u8, e.name, "arg")) {
                    const arg_name = e.attributes.get("name") orelse return error.MissingArgName;
                    const type_str = e.attributes.get("type") orelse return error.MissingArgType;
                    const interface = e.attributes.get("interface") orelse "";

                    const is_array = mem.startsWith(u8, type_str, "array ");
                    const base_type = if (is_array) type_str[6..] else type_str;

                    try args.append(gpa, .{
                        .name = arg_name,
                        .type_str = type_str,
                        .interface = interface,
                        .is_array = is_array,
                        .base_type = base_type,
                    });
                }
            },
            else => {},
        }
    }

    return .{
        .name = name,
        .idx = idx,
        .params = params,
        .returns_type = returns_type,
        .since = 0,
        .args = try args.toOwnedSlice(gpa),
        .is_destructor = is_destructor,
    };
}

fn extractEnumInfo(enum_elem: *const Node.Element, gpa: mem.Allocator) !EnumInfo {
    const name = enum_elem.attributes.get("name") orelse return error.MissingEnumName;

    var values: std.ArrayList(EnumValue) = .empty;
    for (enum_elem.children) |child| {
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
        .values = try values.toOwnedSlice(gpa),
    };
}

pub fn generateSpecCode(gpa: mem.Allocator, doc: *const Document) ![]const u8 {
    const protocol_info = try extractProtocolInfo(doc, gpa);
    defer gpa.free(protocol_info.objects);
    defer gpa.free(protocol_info.enums);

    var output: std.Io.Writer.Allocating = .init(gpa);
    var writer = &output.writer;

    try writer.print(
        \\const std = @import("std");
        \\
        \\const hyprwire = @import("hyprwire");
        \\const types = hyprwire.types;
        \\
    , .{});

    for (protocol_info.enums) |enum_info| {
        const enum_struct_name = try toPascalCase(enum_info.name, gpa);
        defer gpa.free(enum_struct_name);

        try writer.print("\npub const {s} = enum(u32) {{\n", .{enum_struct_name});
        for (enum_info.values) |value| {
            try writer.print("   {s} = {},\n", .{ value.name, value.idx });
        }
        try writer.print("}};\n", .{});
    }

    for (protocol_info.objects) |obj_info| {
        defer gpa.free(obj_info.c2s_methods);
        defer gpa.free(obj_info.s2c_methods);

        const struct_name = try toPascalCase(obj_info.name, gpa);
        defer gpa.free(struct_name);

        try writer.print("\npub const {s}Spec = struct {{\n", .{struct_name});

        try writer.print("    c2s_methods: []const types.Method = &.{{\n", .{});
        for (obj_info.c2s_methods) |method| {
            defer gpa.free(method.params);

            try writer.print(
                \\        .{{
                \\            .idx = {},
                \\            .params = &[_]u8{{
            , .{method.idx});

            for (method.params, 0..) |param_byte, i| {
                if (i > 0) try writer.print(", ", .{});
                try writer.print("@intFromEnum(hyprwire.MessageMagic.{s})", .{getMessageMagicName(param_byte)});
            }

            try writer.print(
                \\}},
                \\            .returns_type = "{s}",
                \\            .since = {},
                \\        }},
                \\
            , .{ method.returns_type, method.since });
        }
        try writer.print("    }},\n\n", .{});

        try writer.print("    s2c_methods: []const types.Method = &.{{\n", .{});
        for (obj_info.s2c_methods) |method| {
            defer gpa.free(method.params);

            try writer.print(
                \\        .{{
                \\            .idx = {},
                \\            .params = &[_]u8{{
            , .{method.idx});

            for (method.params, 0..) |param_byte, i| {
                if (i > 0) try writer.print(", ", .{});
                try writer.print("@intFromEnum(hyprwire.MessageMagic.{s})", .{getMessageMagicName(param_byte)});
            }

            try writer.print(
                \\}},
                \\            .since = {},
                \\        }},
                \\
            , .{method.since});
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
        , .{obj_info.name});
    }

    const protocol_struct_name = try toPascalCase(protocol_info.name, gpa);
    defer gpa.free(protocol_struct_name);

    try writer.print("\npub const {s}ProtocolSpec = struct {{\n", .{protocol_struct_name});

    for (protocol_info.objects) |obj_info| {
        const field_name = try toCamelCase(obj_info.name, gpa);
        defer gpa.free(field_name);
        const struct_name = try toPascalCase(obj_info.name, gpa);
        defer gpa.free(struct_name);

        try writer.print("    {s}: {s}Spec = .{{}},\n", .{ field_name, struct_name });
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
    , .{ protocol_info.name, protocol_info.version, protocol_struct_name, protocol_info.objects.len });

    for (protocol_info.objects) |obj_info| {
        const field_name = try toCamelCase(obj_info.name, gpa);
        defer gpa.free(field_name);

        try writer.print("    types.ProtocolObjectSpec.from(&protocol.{s}),\n", .{field_name});
    }

    try writer.print("}};\n", .{});

    return try output.toOwnedSlice();
}

fn toPascalCase(name: []const u8, gpa: mem.Allocator) ![]const u8 {
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

fn toCamelCase(name: []const u8, gpa: mem.Allocator) ![]const u8 {
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

fn getMessageMagicName(byte: u8) []const u8 {
    return switch (byte) {
        @intFromEnum(MessageMagic.type_array) => "type_array",
        @intFromEnum(MessageMagic.type_varchar) => "type_varchar",
        @intFromEnum(MessageMagic.type_uint) => "type_uint",
        @intFromEnum(MessageMagic.type_int) => "type_int",
        @intFromEnum(MessageMagic.type_fd) => "type_fd",
        else => "unknown",
    };
}
