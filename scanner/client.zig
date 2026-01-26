const std = @import("std");
const mem = std.mem;

const root = @import("root.zig");
const Document = root.Document;
const GenerateError = root.GenerateError;
const writeMethodHandler = root.writeMethodHandler;

const ir = @import("ir.zig");
const Protocol = ir.Protocol;
const Object = ir.Object;
const Method = ir.Method;
const ObjectSet = ir.ObjectSet;

pub fn generateClientCodeForGlobal(gpa: mem.Allocator, doc: *const Document, global_iface: []const u8, requested_version: u32) ![]const u8 {
    const protocol = try Protocol.fromDocument(doc, gpa);

    if (protocol.version < requested_version) {
        return GenerateError.ProtocolVersionTooLow;
    }

    if (mem.eql(u8, global_iface, protocol.name)) {
        return generateClientCode(gpa, protocol, null);
    }

    const selected = try protocol.computeReachableSet(gpa, global_iface, requested_version);
    return generateClientCode(gpa, protocol, selected);
}

fn generateClientCode(gpa: mem.Allocator, protocol: Protocol, selected: ?ObjectSet) ![]const u8 {
    _ = gpa;
    var output: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    const writer = &output.writer;

    try writeHeader(writer, protocol);

    var obj_count: usize = 0;
    for (protocol.objects) |obj| {
        if (selected) |sel| {
            if (!sel.contains(obj.name)) continue;
        }
        obj_count += 1;
    }

    var seen: usize = 0;
    for (protocol.objects) |obj| {
        if (selected) |sel| {
            if (!sel.contains(obj.name)) continue;
        }
        try writeObjectCode(writer, obj, seen > 0);
        seen += 1;
    }

    try writeProtocolImpl(writer, protocol, selected, obj_count);

    return output.toOwnedSlice();
}

fn writeHeader(writer: anytype, protocol: Protocol) !void {
    try writer.print(
        \\const std = @import("std");
        \\
        \\const hyprwire = @import("hyprwire");
        \\const types = hyprwire.types;
        \\const client = types.client;
        \\const spec = hyprwire.proto.{s}.spec;
        \\
        \\
    , .{protocol.name});
}

fn writeObjectCode(writer: anytype, obj: Object, use_short_init: bool) !void {
    for (obj.s2c_methods, 0..) |method, idx| {
        try writeMethodHandler(writer, obj, method, idx);
    }
    try writeObjectStruct(writer, obj, use_short_init);
}

fn writeObjectStruct(writer: anytype, obj: Object, use_short_init: bool) !void {
    try writer.print("pub const {s}Object = struct {{\n", .{obj.name_pascal});

    try writer.print("    pub const Event = union(enum) {{\n", .{});
    for (obj.s2c_methods) |method| {
        try writer.print("        @\"{s}\": struct {{\n", .{method.name});
        for (method.args) |arg| {
            try writer.print("            {s}: {s},\n", .{ arg.name, arg.zig_event_type });
        }
        try writer.print("        }},\n", .{});
    }
    try writer.print("    }};\n\n", .{});

    try writer.print(
        \\    pub const Listener = hyprwire.Trait(.{{
        \\        .{s}Listener = fn (std.mem.Allocator, Event) void,
        \\    }}, null);
        \\
        \\    object: *const types.Object,
        \\    listener: Listener,
        \\    arena: std.heap.ArenaAllocator,
        \\
        \\    const Self = @This();
        \\
    , .{obj.name_camel});

    if (use_short_init) {
        try writer.print(
            \\
            \\    pub fn init(gpa: std.mem.Allocator, listener: Listener, object: *const types.Object) !*Self {{
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
            \\    pub fn init(gpa: std.mem.Allocator, listener: Listener, object: *const types.Object) !*Self {{
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

    for (obj.s2c_methods, 0..) |_, idx| {
        try writer.print("        try object.vtable.listen(object.ptr, gpa, {}, @ptrCast(&{s}_method{}));\n", .{ idx, obj.name_camel, idx });
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

    for (obj.c2s_methods) |method| {
        try writeSendMethod(writer, method);
    }

    if (use_short_init) {
        for (obj.s2c_methods) |method| {
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

    for (obj.s2c_methods, 0..) |method, idx| {
        try writer.print(
            \\
            \\            {} => if (self.listener.@"{s}") |cb|
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

fn writeSendMethod(writer: anytype, method: Method) !void {
    if (method.returns_type.len > 0) {
        try writer.print(
            \\
            \\    pub fn send{s}(self: *Self, gpa: std.mem.Allocator, io: std.Io) ?types.Object {{
            \\        var buffer: [0]types.Arg = undefined;
            \\        var args = types.Args.init(&buffer, .{{}});
            \\        const id = self.object.vtable.call(self.object.ptr, gpa, io, {}, &args) catch return null;
            \\        if (self.object.vtable.clientSock(self.object.ptr)) |sock| {{
            \\            return sock.objectForId(id);
            \\        }}
            \\
            \\        return null;
            \\    }}
            \\
        , .{ method.name_pascal, method.idx });
    } else if (method.is_destructor) {
        try writer.print(
            \\
            \\    pub fn send{s}(self: *Self, gpa: std.mem.Allocator, io: std.Io) !void {{
            \\        var buffer: [0]types.Arg = undefined;
            \\        var args = types.Args.init(&buffer, .{{}});
            \\        _ = try self.object.vtable.call(self.object.ptr, gpa, io, {}, &args);
            \\        self.object.destroy();
            \\    }}
            \\
        , .{ method.name_pascal, method.idx });
    } else if (method.args.len == 0) {
        try writer.print(
            \\
            \\    pub fn send{s}(self: *Self, gpa: std.mem.Allocator, io: std.Io) !void {{
            \\        var buffer: [0]types.Arg = undefined;
            \\        var args = types.Args.init(&buffer, .{{}});
            \\        _ = try self.object.vtable.call(self.object.ptr, gpa, io, {}, &args);
            \\    }}
            \\
        , .{ method.name_pascal, method.idx });
    } else {
        try writer.print("\n    pub fn send{s}(self: *Self, gpa: std.mem.Allocator, io: std.Io", .{method.name_pascal});

        for (method.args) |arg| {
            try writer.print(", @\"{s}\": {s}", .{ arg.name, arg.zig_send_type });
        }

        try writer.print(") !void {{\n        var buffer: [{d}]types.Arg = undefined;\n        var args = types.Args.init(&buffer, .{{\n", .{method.args.len});

        for (method.args) |arg| {
            try writer.print("            @\"{s}\",\n", .{arg.name});
        }

        try writer.print(
            \\        }});
            \\        _ = try self.object.vtable.call(self.object.ptr, gpa, io, {}, &args);
            \\    }}
            \\
        , .{method.idx});
    }
}

fn writeProtocolImpl(writer: anytype, protocol: Protocol, selected: ?ObjectSet, obj_count: usize) !void {
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
    , .{ protocol.name_pascal, obj_count });

    var idx: usize = 0;
    for (protocol.objects) |obj| {
        if (selected) |sel| {
            if (!sel.contains(obj.name)) continue;
        }
        try writer.print(
            \\        impls[{}] = try gpa.create(client.ObjectImplementation);
            \\        errdefer gpa.destroy(impls[{}]);
            \\        impls[{}].* = .{{
            \\            .object_name = "{s}",
            \\            .version = self.version,
            \\        }};
            \\
        , .{ idx, idx, idx, obj.name });
        idx += 1;
        if (idx < obj_count) {
            try writer.print("\n", .{});
        }
    }

    try writer.print(
        \\
        \\        return impls;
        \\    }}
        \\}};
        \\
    , .{});
}
