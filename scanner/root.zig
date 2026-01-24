const std = @import("std");
const mem = std.mem;
const xml = @import("xml");

const MessageMagic = enum(u8) {
    type_varchar = 's',
    type_array = 'a',
    type_uint = 'u',
    type_int = 'i',
    type_fd = 'f',
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
    _ = doc;
    var output: std.Io.Writer.Allocating = .init(gpa);
    var writer = &output.writer;

    try writer.print(
        \\const std = @import("std");
        \\
        \\const hyprwire = @import("hyprwire");
        \\const types = hyprwire.types;
        \\const client = types.client;
        \\const spec = hyprwire.proto.test_protocol_v1.spec;
        \\
        \\fn myManagerV1_method0(r: *types.Object, message: [*:0]const u8) callconv(.c) void {{
        \\    const object: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
        \\    defer _ = object.arena.reset(.retain_capacity);
        \\    var buffer: [32_768]u8 = undefined;
        \\    var fba = std.heap.FixedBufferAllocator.init(&buffer);
        \\    var fallback_allocator = hyprwire.FallbackAllocator{{
        \\        .fba = &fba,
        \\        .fallback = fba.allocator(),
        \\        .fixed = object.arena.allocator(),
        \\    }};
        \\    object.listener.vtable.myManagerV1Listener(
        \\        object.listener.ptr,
        \\        fallback_allocator.allocator(),
        \\        .{{
        \\            .send_message = .{{
        \\                .message = message,
        \\            }},
        \\        }},
        \\    );
        \\}}
        \\
        \\fn myManagerV1_method1(r: *types.Object, message: [*:0]u32) callconv(.c) void {{
        \\    const object: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
        \\    defer _ = object.arena.reset(.retain_capacity);
        \\    var buffer: [32_768]u8 = undefined;
        \\    var fba = std.heap.FixedBufferAllocator.init(&buffer);
        \\    var fallback_allocator = hyprwire.FallbackAllocator{{
        \\        .fba = &fba,
        \\        .fallback = fba.allocator(),
        \\        .fixed = object.arena.allocator(),
        \\    }};
        \\    object.listener.vtable.myManagerV1Listener(
        \\        object.listener.ptr,
        \\        fallback_allocator.allocator(),
        \\        .{{
        \\            .recv_message_array_uint = .{{
        \\                .message = message,
        \\            }},
        \\        }},
        \\    );
        \\}}
        \\
        \\pub const MyManagerV1Object = struct {{
        \\    pub const Event = union(enum) {{
        \\        send_message: struct {{
        \\            message: [*:0]const u8,
        \\        }},
        \\        recv_message_array_uint: struct {{
        \\            message: [*:0]u32,
        \\        }},
        \\    }};
        \\
        \\    pub const Listener = hyprwire.Trait(.{{
        \\        .myManagerV1Listener = fn (std.mem.Allocator, Event) void,
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
        \\        self.* = Self{{
        \\            .listener = listener,
        \\            .object = object,
        \\            .arena = std.heap.ArenaAllocator.init(gpa),
        \\        }};
        \\
        \\        object.vtable.setData(object.ptr, self);
        \\        try object.vtable.listen(object.ptr, gpa, 0, @ptrCast(&myManagerV1_method0));
        \\        try object.vtable.listen(object.ptr, gpa, 1, @ptrCast(&myManagerV1_method1));
        \\
        \\        return self;
        \\    }}
        \\
        \\    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {{
        \\        gpa.destroy(self);
        \\    }}
        \\
        \\    pub fn sendSendMessage(self: *Self, gpa: std.mem.Allocator, message: [:0]const u8) !void {{
        \\        var args = try types.Args.init(gpa, .{{message}});
        \\        defer args.deinit(gpa);
        \\        _ = try self.object.vtable.call(self.object.ptr, gpa, 0, &args);
        \\    }}
        \\
        \\    pub fn sendSendMessageFd(self: *Self, gpa: std.mem.Allocator, message: i32) !void {{
        \\        var args = try types.Args.init(gpa, .{{message}});
        \\        defer args.deinit(gpa);
        \\        _ = try self.object.vtable.call(self.object.ptr, gpa, 1, &args);
        \\    }}
        \\
        \\    pub fn sendSendMessageArray(self: *Self, gpa: std.mem.Allocator, message: []const [:0]const u8) !void {{
        \\        var args = try types.Args.init(gpa, .{{message}});
        \\        defer args.deinit(gpa);
        \\        _ = try self.object.vtable.call(self.object.ptr, gpa, 2, &args);
        \\    }}
        \\
        \\    pub fn sendSendMessageArrayUint(self: *Self, gpa: std.mem.Allocator, message: []const u32) !void {{
        \\        var args = try types.Args.init(gpa, .{{message}});
        \\        defer args.deinit(gpa);
        \\        _ = try self.object.vtable.call(self.object.ptr, gpa, 3, &args);
        \\    }}
        \\
        \\    pub fn sendMakeObject(self: *Self, gpa: std.mem.Allocator) ?types.Object {{
        \\        var args = types.Args.init(gpa, .{{}}) catch return null;
        \\        defer args.deinit(gpa);
        \\        const id = self.object.vtable.call(self.object.ptr, gpa, 4, &args) catch return null;
        \\        if (self.object.vtable.clientSock(self.object.ptr)) |sock| {{
        \\            return sock.objectForId(id);
        \\        }}
        \\
        \\        return null;
        \\    }}
        \\
        \\    pub fn dispatch(
        \\        self: *Self,
        \\        opcode: u16,
        \\        args: anytype,
        \\    ) void {{
        \\        switch (opcode) {{
        \\            0 => if (self.listener.send_message) |cb|
        \\                cb(self, args[0]),
        \\            1 => if (self.listener.recv_message_array_uint) |cb|
        \\                cb(self, args[0]),
        \\            else => {{}},
        \\        }}
        \\    }}
        \\}};
        \\
        \\fn myObjectV1_method0(r: *types.Object, message: [*:0]const u8) callconv(.c) void {{
        \\    const object: *MyObjectV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
        \\    defer _ = object.arena.reset(.retain_capacity);
        \\    var buffer: [32_768]u8 = undefined;
        \\    var fba = std.heap.FixedBufferAllocator.init(&buffer);
        \\    var fallback_allocator = hyprwire.FallbackAllocator{{
        \\        .fba = &fba,
        \\        .fallback = fba.allocator(),
        \\        .fixed = object.arena.allocator(),
        \\    }};
        \\    object.listener.vtable.myObjectV1Listener(
        \\        object.listener.ptr,
        \\        fallback_allocator.allocator(),
        \\        .{{
        \\            .send_message = .{{
        \\                .message = message,
        \\            }},
        \\        }},
        \\    );
        \\}}
        \\
        \\pub const MyObjectV1Object = struct {{
        \\    pub const Event = union(enum) {{
        \\        send_message: struct {{
        \\            message: [*:0]const u8,
        \\        }},
        \\    }};
        \\
        \\    pub const Listener = hyprwire.Trait(.{{
        \\        .myObjectV1Listener = fn (std.mem.Allocator, Event) void,
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
        \\            .object = object,
        \\            .listener = listener,
        \\            .arena = std.heap.ArenaAllocator.init(gpa),
        \\        }};
        \\
        \\        object.vtable.setData(object.ptr, self);
        \\        try object.vtable.listen(object.ptr, gpa, 0, @ptrCast(&myObjectV1_method0));
        \\
        \\        return self;
        \\    }}
        \\
        \\    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {{
        \\        gpa.destroy(self);
        \\    }}
        \\
        \\    pub fn sendSendMessage(self: *Self, gpa: std.mem.Allocator, message: [:0]const u8) !void {{
        \\        var args = try types.Args.init(gpa, .{{message}});
        \\        defer args.deinit(gpa);
        \\        _ = try self.object.vtable.call(self.object.ptr, gpa, 0, &args);
        \\    }}
        \\
        \\    pub fn sendSendEnum(self: *Self, gpa: std.mem.Allocator, message: spec.MyEnum) !void {{
        \\        var args = try types.Args.init(gpa, .{{message}});
        \\        defer args.deinit(gpa);
        \\        _ = try self.object.vtable.call(self.object.ptr, gpa, 1, &args);
        \\    }}
        \\
        \\    pub fn sendDestroy(self: *Self, gpa: std.mem.Allocator) !void {{
        \\        var args = try types.Args.init(gpa, .{{}});
        \\        defer args.deinit(gpa);
        \\        _ = try self.object.vtable.call(self.object.ptr, gpa, 2, &args);
        \\        self.object.destroy();
        \\    }}
        \\
        \\    pub fn setSendMessage(self: *Self, callback: *const fn ([*:0]const u8) void) void {{
        \\        self.listener.send_message = callback;
        \\    }}
        \\
        \\    pub fn dispatch(
        \\        self: *Self,
        \\        opcode: u16,
        \\        args: anytype,
        \\    ) void {{
        \\        switch (opcode) {{
        \\            0 => if (self.listener.send_message) |cb|
        \\                cb(self, args[0]),
        \\            else => {{}},
        \\        }}
        \\    }}
        \\}};
        \\
        \\pub const TestProtocolV1Impl = struct {{
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
        \\        const impls = try gpa.alloc(*client.ObjectImplementation, 2);
        \\        errdefer gpa.free(impls);
        \\
        \\        impls[0] = try gpa.create(client.ObjectImplementation);
        \\        errdefer gpa.destroy(impls[0]);
        \\        impls[0].* = .{{
        \\            .object_name = "my_manager_v1",
        \\            .version = self.version,
        \\        }};
        \\
        \\        impls[1] = try gpa.create(client.ObjectImplementation);
        \\        errdefer gpa.destroy(impls[1]);
        \\        impls[1].* = .{{
        \\            .object_name = "my_object_v1",
        \\            .version = self.version,
        \\        }};
        \\
        \\        return impls;
        \\    }}
        \\}};
    , .{});

    return output.toOwnedSlice();
}

pub fn generateServerCode(gpa: mem.Allocator, doc: *const Document) ![]const u8 {
    _ = doc;
    var output: std.Io.Writer.Allocating = .init(gpa);
    var writer = &output.writer;

    try writer.print(
        \\const std = @import("std");
        \\
        \\const hyprwire = @import("hyprwire");
        \\const types = hyprwire.types;
        \\const server = types.server;
        \\const spec = hyprwire.proto.test_protocol_v1.spec;
        \\
        \\
    , .{});
    try writer.print(
        \\fn myManagerV1_method0(r: *types.Object, message: [*:0]const u8) callconv(.c) void {{
        \\    const object: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
        \\    defer _ = object.arena.reset(.retain_capacity);
        \\    var buffer: [32_768]u8 = undefined;
        \\    var fba = std.heap.FixedBufferAllocator.init(&buffer);
        \\    var fallback_allocator = hyprwire.FallbackAllocator{{
        \\        .fba = &fba,
        \\        .fallback = fba.allocator(),
        \\        .fixed = object.arena.allocator(),
        \\    }};
        \\    object.listener.vtable.myManagerV1Listener(
        \\        object.listener.ptr,
        \\        fallback_allocator.allocator(),
        \\        .{{ .send_message = .{{
        \\            .message = message,
        \\        }} }},
        \\    );
        \\}}
        \\
        \\fn myManagerV1_method1(r: *types.Object, fd: i32) callconv(.c) void {{
        \\    const object: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
        \\    defer _ = object.arena.reset(.retain_capacity);
        \\    var buffer: [32_768]u8 = undefined;
        \\    var fba = std.heap.FixedBufferAllocator.init(&buffer);
        \\    var fallback_allocator = hyprwire.FallbackAllocator{{
        \\        .fba = &fba,
        \\        .fallback = fba.allocator(),
        \\        .fixed = object.arena.allocator(),
        \\    }};
        \\    object.listener.vtable.myManagerV1Listener(
        \\        object.listener.ptr,
        \\        fallback_allocator.allocator(),
        \\        .{{ .send_message_fd = .{{
        \\            .message = fd,
        \\        }} }},
        \\    );
        \\}}
        \\
        \\fn myManagerV1_method2(r: *types.Object, message: [*][*:0]const u8, message_len: u32) callconv(.c) void {{
        \\    const object: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
        \\    defer _ = object.arena.reset(.retain_capacity);
        \\    var buffer: [32_768]u8 = undefined;
        \\    var fba = std.heap.FixedBufferAllocator.init(&buffer);
        \\    var fallback_allocator = hyprwire.FallbackAllocator{{
        \\        .fba = &fba,
        \\        .fallback = fba.allocator(),
        \\        .fixed = object.arena.allocator(),
        \\    }};
        \\    object.listener.vtable.myManagerV1Listener(
        \\        object.listener.ptr,
        \\        fallback_allocator.allocator(),
        \\        .{{ .send_message_array = .{{
        \\            .message = fallback_allocator.allocator().dupe([*:0]const u8, message[0..message_len]) catch return,
        \\        }} }},
        \\    );
        \\}}
        \\
        \\fn myManagerV1_method3(r: *types.Object, message: [*:0]u32) callconv(.c) void {{
        \\    const object: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
        \\    defer _ = object.arena.reset(.retain_capacity);
        \\    var buffer: [32_768]u8 = undefined;
        \\    var fba = std.heap.FixedBufferAllocator.init(&buffer);
        \\    var fallback_allocator = hyprwire.FallbackAllocator{{
        \\        .fba = &fba,
        \\        .fallback = fba.allocator(),
        \\        .fixed = object.arena.allocator(),
        \\    }};
        \\    object.listener.vtable.myManagerV1Listener(
        \\        object.listener.ptr,
        \\        fallback_allocator.allocator(),
        \\        .{{ .send_message_array_uint = .{{
        \\            .message = message,
        \\        }} }},
        \\    );
        \\}}
        \\
        \\fn myManagerV1_method4(r: *types.Object, seq: u32) callconv(.c) void {{
        \\    const object: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
        \\    defer _ = object.arena.reset(.retain_capacity);
        \\    var buffer: [32_768]u8 = undefined;
        \\    var fba = std.heap.FixedBufferAllocator.init(&buffer);
        \\    var fallback_allocator = hyprwire.FallbackAllocator{{
        \\        .fba = &fba,
        \\        .fallback = fba.allocator(),
        \\        .fixed = object.arena.allocator(),
        \\    }};
        \\    object.listener.vtable.myManagerV1Listener(
        \\        object.listener.ptr,
        \\        fallback_allocator.allocator(),
        \\        .{{ .make_object = .{{
        \\            .seq = seq,
        \\        }} }},
        \\    );
        \\}}
    , .{});
    try writer.print(
        \\
        \\
        \\pub const MyManagerV1Object = struct {{
        \\
    , .{});
    try writer.print(
        \\    pub const Event = union(enum) {{
        \\        send_message: struct {{
        \\            message: [*:0]const u8,
        \\        }},
        \\        send_message_fd: struct {{
        \\            message: i32,
        \\        }},
        \\        send_message_array: struct {{
        \\            message: [][*:0]const u8,
        \\        }},
        \\        send_message_array_uint: struct {{
        \\            message: [*:0]u32,
        \\        }},
        \\        make_object: struct {{
        \\            seq: u32,
        \\        }},
        \\    }};
        \\
    , .{});
    try writer.print(
        \\
        \\    pub const Listener = hyprwire.Trait(.{{
        \\        .myManagerV1Listener = fn (std.mem.Allocator, Event) void,
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
        \\            .listener = listener,
        \\            .object = object,
        \\            .arena = std.heap.ArenaAllocator.init(gpa),
        \\        }};
        \\
        \\        object.vtable.setData(object.ptr, self);
        \\
        \\
    , .{});
    try writer.print(
        \\        try object.vtable.listen(object.ptr, gpa, 0, @ptrCast(&myManagerV1_method0));
        \\        try object.vtable.listen(object.ptr, gpa, 1, @ptrCast(&myManagerV1_method1));
        \\        try object.vtable.listen(object.ptr, gpa, 2, @ptrCast(&myManagerV1_method2));
        \\        try object.vtable.listen(object.ptr, gpa, 3, @ptrCast(&myManagerV1_method3));
        \\        try object.vtable.listen(object.ptr, gpa, 4, @ptrCast(&myManagerV1_method4));
    , .{});
    try writer.print(
        \\
        \\
        \\        return self;
        \\    }}
        \\
    , .{});
    try writer.print(
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
        \\    pub fn sendSendMessage(self: *Self, gpa: std.mem.Allocator, message: [:0]const u8) !void {{
        \\        var args = try types.Args.init(gpa, .{{message}});
        \\        defer args.deinit(gpa);
        \\        _ = try self.object.vtable.call(self.object.ptr, gpa, 0, &args);
        \\    }}
        \\
        \\    pub fn sendRecvMessageArrayUint(self: *Self, gpa: std.mem.Allocator, message: []const u32) !void {{
        \\        var args = try types.Args.init(gpa, .{{message}});
        \\        defer args.deinit(gpa);
        \\        _ = try self.object.vtable.call(self.object.ptr, gpa, 1, &args);
        \\    }}
        \\}};
        \\
        \\
    , .{});
    try writer.print(
        \\fn myObjectV1_method0(r: *types.Object, message: [*:0]const u8) callconv(.c) void {{
        \\    const object: *MyObjectV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
        \\    defer _ = object.arena.reset(.retain_capacity);
        \\    var buffer: [32_768]u8 = undefined;
        \\    var fba = std.heap.FixedBufferAllocator.init(&buffer);
        \\    var fallback_allocator = hyprwire.FallbackAllocator{{
        \\        .fba = &fba,
        \\        .fallback = fba.allocator(),
        \\        .fixed = object.arena.allocator(),
        \\    }};
        \\    object.listener.vtable.myObjectV1Listener(
        \\        object.listener.ptr,
        \\        fallback_allocator.allocator(),
        \\        .{{ .send_message = .{{
        \\            .message = message,
        \\        }} }},
        \\    );
        \\}}
        \\
        \\fn myObjectV1_method1(r: *types.Object, value: i32) callconv(.c) void {{
        \\    const object: *MyObjectV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
        \\    defer _ = object.arena.reset(.retain_capacity);
        \\    var buffer: [32_768]u8 = undefined;
        \\    var fba = std.heap.FixedBufferAllocator.init(&buffer);
        \\    var fallback_allocator = hyprwire.FallbackAllocator{{
        \\        .fba = &fba,
        \\        .fallback = fba.allocator(),
        \\        .fixed = object.arena.allocator(),
        \\    }};
        \\    object.listener.vtable.myObjectV1Listener(
        \\        object.listener.ptr,
        \\        fallback_allocator.allocator(),
        \\        .{{ .send_enum = .{{
        \\            .message = @enumFromInt(value),
        \\        }} }},
        \\    );
        \\}}
        \\
        \\fn myObjectV1_method2(r: *types.Object) callconv(.c) void {{
        \\    const object: *MyObjectV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
        \\    defer _ = object.arena.reset(.retain_capacity);
        \\    var buffer: [32_768]u8 = undefined;
        \\    var fba = std.heap.FixedBufferAllocator.init(&buffer);
        \\    var fallback_allocator = hyprwire.FallbackAllocator{{
        \\        .fba = &fba,
        \\        .fallback = fba.allocator(),
        \\        .fixed = object.arena.allocator(),
        \\    }};
        \\    object.listener.vtable.myObjectV1Listener(
        \\        object.listener.ptr,
        \\        fallback_allocator.allocator(),
        \\        .{{ .destroy = .{{}} }},
        \\    );
        \\}}
        \\
    , .{});
    try writer.print(
        \\
        \\pub const MyObjectV1Object = struct {{
        \\    pub const Event = union(enum) {{
        \\        send_message: struct {{
        \\            message: [*:0]const u8,
        \\        }},
        \\        send_enum: struct {{
        \\            message: spec.MyEnum,
        \\        }},
        \\        destroy: struct {{}},
        \\    }};
        \\
    , .{});
    try writer.print(
        \\
        \\    pub const Listener = hyprwire.Trait(.{{
        \\        .myObjectV1Listener = fn (std.mem.Allocator, Event) void,
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
        \\            .object = object,
        \\            .listener = listener,
        \\            .arena = std.heap.ArenaAllocator.init(gpa),
        \\        }};
        \\
        \\        object.vtable.setData(object.ptr, self);
        \\
        \\
    , .{});
    try writer.print(
        \\        try object.vtable.listen(object.ptr, gpa, 0, @ptrCast(&myObjectV1_method0));
        \\        try object.vtable.listen(object.ptr, gpa, 1, @ptrCast(&myObjectV1_method1));
        \\        try object.vtable.listen(object.ptr, gpa, 2, @ptrCast(&myObjectV1_method2));
    , .{});
    try writer.print(
        \\
        \\        return self;
        \\    }}
        \\
        \\    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {{
        \\        self.arena.deinit();
        \\        gpa.destroy(self);
        \\    }}
        \\
    , .{});
    try writer.print(
        \\
        \\    pub fn setOnDeinit(self: *Self, @"fn": *const fn (*Self) void) void {{
        \\        self.object.vtable.setOnDeinit(self.object.ptr, @"fn");
        \\    }}
        \\
        \\    pub fn err(self: *Self, gpa: std.mem.Allocator, code: u32, message: [:0]const u8) !void {{
        \\        try self.object.vtable.err(self.object.ptr, gpa, code, message);
        \\    }}
        \\
        \\    pub fn sendSendMessage(self: *Self, gpa: std.mem.Allocator, message: [:0]const u8) !void {{
        \\        var args = try types.Args.init(gpa, .{{message}});
        \\        defer args.deinit(gpa);
        \\        _ = try self.object.vtable.call(self.object.ptr, gpa, 0, &args);
        \\    }}
        \\}};
        \\
    , .{});
    try writer.print(
        \\
        \\pub const TestProtocolV1Listener = hyprwire.Trait(.{{
        \\    .bind = fn (*types.Object) void,
        \\}}, null);
        \\
        \\pub const TestProtocolV1Impl = struct {{
        \\    version: u32,
        \\    listener: TestProtocolV1Listener,
        \\
        \\    const Self = @This();
        \\
        \\    pub fn init(
        \\        version: u32,
        \\        listener: TestProtocolV1Listener,
        \\    ) Self {{
        \\        return .{{
        \\            .version = version,
        \\            .listener = listener,
        \\        }};
        \\    }}
        \\
        \\    pub fn protocol(_: *Self) types.ProtocolSpec {{
        \\        return types.ProtocolSpec.from(&spec.TestProtocolV1ProtocolSpec{{}});
        \\    }}
        \\
    , .{});
    try writer.print(
        \\
        \\    pub fn implementation(
        \\        self: *Self,
        \\        gpa: std.mem.Allocator,
        \\    ) ![]*server.ObjectImplementation {{
        \\        const impls = try gpa.alloc(*server.ObjectImplementation, 2);
        \\        errdefer gpa.free(impls);
        \\
    , .{});
    try writer.print(
        \\
        \\        impls[0] = try gpa.create(server.ObjectImplementation);
        \\        errdefer gpa.destroy(impls[0]);
        \\        impls[0].* = .{{
        \\            .context = self.listener.ptr,
        \\            .object_name = "my_manager_v1",
        \\            .version = self.version,
        \\            .onBind = self.listener.vtable.bind,
        \\        }};
        \\
        \\        impls[1] = try gpa.create(server.ObjectImplementation);
        \\        errdefer gpa.destroy(impls[1]);
        \\        impls[1].* = .{{
        \\            .context = self.listener.ptr,
        \\            .object_name = "my_object_v1",
        \\            .version = self.version,
        \\        }};
        \\
    , .{});
    try writer.print(
        \\
        \\        return impls;
        \\    }}
        \\}};
    , .{});

    return output.toOwnedSlice();
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

const MethodInfo = struct {
    name: []const u8,
    idx: u32,
    params: []const u8,
    returns_type: []const u8,
    since: u32,
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

    const params = try generateMethodParams(method_elem, gpa);

    var returns_type: []const u8 = "";
    for (method_elem.children) |child| {
        switch (child) {
            .element => |e| {
                if (mem.eql(u8, e.name, "returns")) {
                    returns_type = e.attributes.get("iface") orelse "";
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
