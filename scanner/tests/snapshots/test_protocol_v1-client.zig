const std = @import("std");

const hyprwire = @import("hyprwire");
const types = hyprwire.types;
const client = types.client;
const spec = hyprwire.proto.test_protocol_v1.spec;

fn myManagerV1_method0(r: *types.Object, @"message": [*:0]const u8) callconv(.c) void {
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
        .{
            .@"send_message" = .{
                .message = message,
            },
        },
    );
}

fn myManagerV1_method1(r: *types.Object, @"message": [*:0]u32) callconv(.c) void {
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
        .{
            .@"recv_message_array_uint" = .{
                .message = message,
            },
        },
    );
}

pub const MyManagerV1Object = struct {
    pub const Event = union(enum) {
        @"send_message": struct {
            message: [*:0]const u8,
        },
        @"recv_message_array_uint": struct {
            message: [*:0]u32,
        },
    };

    pub const Listener = hyprwire.Trait(.{
        .myManagerV1Listener = fn (std.mem.Allocator, Event) void,
    }, null);

    object: *const types.Object,
    listener: Listener,
    arena: std.heap.ArenaAllocator,

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator, listener: Listener, object: *const types.Object) !*Self {
        const self = try gpa.create(Self);
        self.* = Self{
            .listener = listener,
            .object = object,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };

        object.vtable.setData(object.ptr, self);
        try object.vtable.listen(object.ptr, gpa, 0, @ptrCast(&myManagerV1_method0));
        try object.vtable.listen(object.ptr, gpa, 1, @ptrCast(&myManagerV1_method1));

        return self;
    }

    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        gpa.destroy(self);
    }

    pub fn sendSendMessage(self: *Self, gpa: std.mem.Allocator, @"message": [:0]const u8) !void {
        var args = try types.Args.init(gpa, .{
            @"message",
        });
        defer args.deinit(gpa);
        _ = try self.object.vtable.call(self.object.ptr, gpa, 0, &args);
    }

    pub fn sendSendMessageFd(self: *Self, gpa: std.mem.Allocator, @"message": i32) !void {
        var args = try types.Args.init(gpa, .{
            @"message",
        });
        defer args.deinit(gpa);
        _ = try self.object.vtable.call(self.object.ptr, gpa, 1, &args);
    }

    pub fn sendSendMessageArray(self: *Self, gpa: std.mem.Allocator, @"message": []const [:0]const u8) !void {
        var args = try types.Args.init(gpa, .{
            @"message",
        });
        defer args.deinit(gpa);
        _ = try self.object.vtable.call(self.object.ptr, gpa, 2, &args);
    }

    pub fn sendSendMessageArrayUint(self: *Self, gpa: std.mem.Allocator, @"message": []const u32) !void {
        var args = try types.Args.init(gpa, .{
            @"message",
        });
        defer args.deinit(gpa);
        _ = try self.object.vtable.call(self.object.ptr, gpa, 3, &args);
    }

    pub fn sendMakeObject(self: *Self, gpa: std.mem.Allocator) ?types.Object {
        var args = types.Args.init(gpa, .{}) catch return null;
        defer args.deinit(gpa);
        const id = self.object.vtable.call(self.object.ptr, gpa, 4, &args) catch return null;
        if (self.object.vtable.clientSock(self.object.ptr)) |sock| {
            return sock.objectForId(id);
        }

        return null;
    }

    pub fn dispatch(
        self: *Self,
        opcode: u16,
        args: anytype,
    ) void {
        switch (opcode) {
            0 => if (self.listener.@"send_message") |cb|
                cb(self, args[0]),
            1 => if (self.listener.@"recv_message_array_uint") |cb|
                cb(self, args[0]),
            else => {},
        }
    }
};

fn myObjectV1_method0(r: *types.Object, @"message": [*:0]const u8) callconv(.c) void {
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
        .{
            .@"send_message" = .{
                .message = message,
            },
        },
    );
}

pub const MyObjectV1Object = struct {
    pub const Event = union(enum) {
        @"send_message": struct {
            message: [*:0]const u8,
        },
    };

    pub const Listener = hyprwire.Trait(.{
        .myObjectV1Listener = fn (std.mem.Allocator, Event) void,
    }, null);

    object: *const types.Object,
    listener: Listener,
    arena: std.heap.ArenaAllocator,

    const Self = @This();

    pub fn init(gpa: std.mem.Allocator, listener: Listener, object: *const types.Object) !*Self {
        const self = try gpa.create(Self);
        self.* = .{
            .object = object,
            .listener = listener,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };

        object.vtable.setData(object.ptr, self);
        try object.vtable.listen(object.ptr, gpa, 0, @ptrCast(&myObjectV1_method0));

        return self;
    }

    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        gpa.destroy(self);
    }

    pub fn sendSendMessage(self: *Self, gpa: std.mem.Allocator, @"message": [:0]const u8) !void {
        var args = try types.Args.init(gpa, .{
            @"message",
        });
        defer args.deinit(gpa);
        _ = try self.object.vtable.call(self.object.ptr, gpa, 0, &args);
    }

    pub fn sendSendEnum(self: *Self, gpa: std.mem.Allocator, @"message": spec.MyEnum) !void {
        var args = try types.Args.init(gpa, .{
            @"message",
        });
        defer args.deinit(gpa);
        _ = try self.object.vtable.call(self.object.ptr, gpa, 1, &args);
    }

    pub fn sendDestroy(self: *Self, gpa: std.mem.Allocator) !void {
        var args = try types.Args.init(gpa, .{});
        defer args.deinit(gpa);
        _ = try self.object.vtable.call(self.object.ptr, gpa, 2, &args);
        self.object.destroy();
    }

    pub fn setSendMessage(self: *Self, callback: *const fn ([*:0]const u8) void) void {
        self.listener.send_message = callback;
    }

    pub fn dispatch(
        self: *Self,
        opcode: u16,
        args: anytype,
    ) void {
        switch (opcode) {
            0 => if (self.listener.@"send_message") |cb|
                cb(self, args[0]),
            else => {},
        }
    }
};

pub const TestProtocolV1Impl = struct {
    version: u32,

    const Self = @This();

    pub fn init(version: u32) Self {
        return .{ .version = version };
    }

    pub fn protocol(self: *Self) types.ProtocolSpec {
        _ = self;
        return types.ProtocolSpec.from(&spec.protocol);
    }

    pub fn implementation(
        self: *Self,
        gpa: std.mem.Allocator,
    ) ![]*client.ObjectImplementation {
        const impls = try gpa.alloc(*client.ObjectImplementation, 2);
        errdefer gpa.free(impls);

        impls[0] = try gpa.create(client.ObjectImplementation);
        errdefer gpa.destroy(impls[0]);
        impls[0].* = .{
            .object_name = "my_manager_v1",
            .version = self.version,
        };

        impls[1] = try gpa.create(client.ObjectImplementation);
        errdefer gpa.destroy(impls[1]);
        impls[1].* = .{
            .object_name = "my_object_v1",
            .version = self.version,
        };

        return impls;
    }
};
