const std = @import("std");

const hyprwire = @import("hyprwire");
const types = hyprwire.types;
const server = types.server;
const spec = hyprwire.proto.test_protocol_v1.spec;

fn myManagerV1_method0(r: *types.Object, message: [*:0]const u8) callconv(.c) void {
    const object: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    defer _ = object.arena.reset(.retain_capacity);
    var buffer: [32_768]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var fallback_allocator = hyprwire.FallbackAllocator{
        .fba = &fba,
        .fallback = fba.allocator(),
        .fixed = object.arena.allocator(),
    };
    object.listener.vtable.myManagerV1Listener(
        object.listener.ptr,
        fallback_allocator.allocator(),
        .{ .@"send_message" = .{
            .@"message" = message,
        } },
    );
}

fn myManagerV1_method1(r: *types.Object, fd: i32) callconv(.c) void {
    const object: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    defer _ = object.arena.reset(.retain_capacity);
    var buffer: [32_768]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var fallback_allocator = hyprwire.FallbackAllocator{
        .fba = &fba,
        .fallback = fba.allocator(),
        .fixed = object.arena.allocator(),
    };
    object.listener.vtable.myManagerV1Listener(
        object.listener.ptr,
        fallback_allocator.allocator(),
        .{ .@"send_message_fd" = .{
            .@"message" = fd,
        } },
    );
}

fn myManagerV1_method2(r: *types.Object, message: [*][*:0]const u8, message_len: u32) callconv(.c) void {
    const object: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    defer _ = object.arena.reset(.retain_capacity);
    var buffer: [32_768]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var fallback_allocator = hyprwire.FallbackAllocator{
        .fba = &fba,
        .fallback = fba.allocator(),
        .fixed = object.arena.allocator(),
    };
    object.listener.vtable.myManagerV1Listener(
        object.listener.ptr,
        fallback_allocator.allocator(),
        .{ .@"send_message_array" = .{
            .@"message" = fallback_allocator.allocator().dupe([*:0]const u8, message[0..message_len]) catch return,
        } },
    );
}

fn myManagerV1_method3(r: *types.Object, message: [*:0]u32) callconv(.c) void {
    const object: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    defer _ = object.arena.reset(.retain_capacity);
    var buffer: [32_768]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var fallback_allocator = hyprwire.FallbackAllocator{
        .fba = &fba,
        .fallback = fba.allocator(),
        .fixed = object.arena.allocator(),
    };
    object.listener.vtable.myManagerV1Listener(
        object.listener.ptr,
        fallback_allocator.allocator(),
        .{ .@"send_message_array_uint" = .{
            .@"message" = message,
        } },
    );
}

fn myManagerV1_method4(r: *types.Object, seq: u32) callconv(.c) void {
    const object: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    defer _ = object.arena.reset(.retain_capacity);
    var buffer: [32_768]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var fallback_allocator = hyprwire.FallbackAllocator{
        .fba = &fba,
        .fallback = fba.allocator(),
        .fixed = object.arena.allocator(),
    };
    object.listener.vtable.myManagerV1Listener(
        object.listener.ptr,
        fallback_allocator.allocator(),
        .{ .@"make_object" = .{
            .seq = seq,
        } },
    );
}

pub const MyManagerV1Object = struct {
    pub const Event = union(enum) {
        @"send_message": struct {
            @"message": [*:0]const u8,
        },
        @"send_message_fd": struct {
            @"message": i32,
        },
        @"send_message_array": struct {
            @"message": [][*:0]const u8,
        },
        @"send_message_array_uint": struct {
            @"message": [*:0]u32,
        },
        @"make_object": struct {
            seq: u32,
        },
    };

    pub const Listener = hyprwire.Trait(.{
        .myManagerV1Listener = fn (std.mem.Allocator, Event) void,
    }, null);

    object: *types.Object,
    listener: Listener,
    arena: std.heap.ArenaAllocator,

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator, listener: Listener, object: *types.Object) !*Self {
        const self = try gpa.create(Self);
        self.* = .{
            .listener = listener,
            .object = object,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };

        object.vtable.setData(object.ptr, self);

        try object.vtable.listen(object.ptr, gpa, 0, @ptrCast(&myManagerV1_method0));
        try object.vtable.listen(object.ptr, gpa, 1, @ptrCast(&myManagerV1_method1));
        try object.vtable.listen(object.ptr, gpa, 2, @ptrCast(&myManagerV1_method2));
        try object.vtable.listen(object.ptr, gpa, 3, @ptrCast(&myManagerV1_method3));
        try object.vtable.listen(object.ptr, gpa, 4, @ptrCast(&myManagerV1_method4));

        return self;
    }
    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }

    pub fn getObject(self: *Self) *types.Object {
        return self.object;
    }

    pub fn err(self: *Self, code: u32, message: []const u8) void {
        self.object.vtable.err(self.object.ptr, code, message);
    }

    pub fn setOnDeinit(self: *Self, @"fn": *const fn () void) void {
        self.object.vtable.setOnDeinit(self.object.ptr, @"fn");
    }

    pub fn sendSendMessage(self: *Self, gpa: std.mem.Allocator, message: [:0]const u8) !void {
        var args = try types.Args.init(gpa, .{@"message",
});
        defer args.deinit(gpa);
        _ = try self.object.vtable.call(self.object.ptr, gpa, 0, &args);
    }

    pub fn sendRecvMessageArrayUint(self: *Self, gpa: std.mem.Allocator, message: []const u32) !void {
        var args = try types.Args.init(gpa, .{@"message",
});
        defer args.deinit(gpa);
        _ = try self.object.vtable.call(self.object.ptr, gpa, 1, &args);
    }
};

fn myObjectV1_method0(r: *types.Object, message: [*:0]const u8) callconv(.c) void {
    const object: *MyObjectV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    defer _ = object.arena.reset(.retain_capacity);
    var buffer: [32_768]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var fallback_allocator = hyprwire.FallbackAllocator{
        .fba = &fba,
        .fallback = fba.allocator(),
        .fixed = object.arena.allocator(),
    };
    object.listener.vtable.myObjectV1Listener(
        object.listener.ptr,
        fallback_allocator.allocator(),
        .{ .@"send_message" = .{
            .@"message" = message,
        } },
    );
}

fn myObjectV1_method1(r: *types.Object, value: i32) callconv(.c) void {
    const object: *MyObjectV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    defer _ = object.arena.reset(.retain_capacity);
    var buffer: [32_768]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var fallback_allocator = hyprwire.FallbackAllocator{
        .fba = &fba,
        .fallback = fba.allocator(),
        .fixed = object.arena.allocator(),
    };
    object.listener.vtable.myObjectV1Listener(
        object.listener.ptr,
        fallback_allocator.allocator(),
        .{ .@"send_enum" = .{
            .@"message" = @enumFromInt(value),
        } },
    );
}

fn myObjectV1_method2(r: *types.Object) callconv(.c) void {
    const object: *MyObjectV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    defer _ = object.arena.reset(.retain_capacity);
    var buffer: [32_768]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var fallback_allocator = hyprwire.FallbackAllocator{
        .fba = &fba,
        .fallback = fba.allocator(),
        .fixed = object.arena.allocator(),
    };
    object.listener.vtable.myObjectV1Listener(
        object.listener.ptr,
        fallback_allocator.allocator(),
        .{ .@"destroy" = .{} },
    );
}

pub const MyObjectV1Object = struct {
    pub const Event = union(enum) {
        @"send_message": struct {
            @"message": [*:0]const u8,
        },
        @"send_enum": struct {
            @"message": spec.MyEnum,
        },
        @"destroy": struct {},
    };

    pub const Listener = hyprwire.Trait(.{
        .myObjectV1Listener = fn (std.mem.Allocator, Event) void,
    }, null);

    object: *types.Object,
    listener: Listener,
    arena: std.heap.ArenaAllocator,

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator, listener: Listener, object: *types.Object) !*Self {
        const self = try gpa.create(Self);
        self.* = .{
            .object = object,
            .listener = listener,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };

        object.vtable.setData(object.ptr, self);

        try object.vtable.listen(object.ptr, gpa, 0, @ptrCast(&myObjectV1_method0));
        try object.vtable.listen(object.ptr, gpa, 1, @ptrCast(&myObjectV1_method1));
        try object.vtable.listen(object.ptr, gpa, 2, @ptrCast(&myObjectV1_method2));
        return self;
    }

    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
    }

    pub fn setOnDeinit(self: *Self, @"fn": *const fn (*Self) void) void {
        self.object.vtable.setOnDeinit(self.object.ptr, @"fn");
    }

    pub fn err(self: *Self, gpa: std.mem.Allocator, code: u32, message: [:0]const u8) !void {
        try self.object.vtable.err(self.object.ptr, gpa, code, message);
    }

    pub fn sendSendMessage(self: *Self, gpa: std.mem.Allocator, message: [:0]const u8) !void {
        var args = try types.Args.init(gpa, .{@"message",
});
        defer args.deinit(gpa);
        _ = try self.object.vtable.call(self.object.ptr, gpa, 0, &args);
    }
};

pub const TestProtocolV1Listener = hyprwire.Trait(.{
    .bind = fn (*types.Object) void,
}, null);

pub const TestProtocolV1Impl = struct {
    version: u32,
    listener: TestProtocolV1Listener,

    const Self = @This();

    pub fn init(
        version: u32,
        listener: TestProtocolV1Listener,
    ) Self {
        return .{
            .version = version,
            .listener = listener,
        };
    }

    pub fn protocol(_: *Self) types.ProtocolSpec {
        return types.ProtocolSpec.from(&spec.TestProtocolV1ProtocolSpec{});
    }

    pub fn implementation(
        self: *Self,
        gpa: std.mem.Allocator,
    ) ![]*server.ObjectImplementation {
        const impls = try gpa.alloc(*server.ObjectImplementation, 2);
        errdefer gpa.free(impls);

        impls[0] = try gpa.create(server.ObjectImplementation);
        errdefer gpa.destroy(impls[0]);
        impls[0].* = .{
            .context = self.listener.ptr,
            .object_name = "my_manager_v1",
            .version = self.version,
            .onBind = self.listener.vtable.bind,
        };

        impls[1] = try gpa.create(server.ObjectImplementation);
        errdefer gpa.destroy(impls[1]);
        impls[1].* = .{
            .context = self.listener.ptr,
            .object_name = "my_object_v1",
            .version = self.version,
        };

        return impls;
    }
};