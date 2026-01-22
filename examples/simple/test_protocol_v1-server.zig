const hyprwire = @import("hyprwire");
const std = @import("std");
const spec = @import("test_protocol_v1-spec.zig");

const mem = std.mem;
const heap = std.heap;

const ProtocolSpec = hyprwire.types.ProtocolSpec;
const Object = hyprwire.types.Object;
const ServerObjectImplementation = hyprwire.types.server_impl.ServerObjectImplementation;
const TestProtocolV1ProtocolSpec = spec.TestProtocolV1ProtocolSpec;
const Args = hyprwire.types.Args;

fn myManagerV1_method0(r: *Object, message: [*:0]const u8) callconv(.c) void {
    const object: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    defer _ = object.arena.reset(.retain_capacity);
    var buffer: [32_768]u8 = undefined;
    var fba = heap.FixedBufferAllocator.init(&buffer);
    var fallback_allocator = hyprwire.FallbackAllocator{
        .fba = &fba,
        .fallback = fba.allocator(),
        .fixed = object.arena.allocator(),
    };
    object.listener.vtable.myManagerV1Listener(
        object.listener.ptr,
        fallback_allocator.allocator(),
        .{ .send_message = .{
            .message = message,
        } },
    );
}

fn myManagerV1_method1(r: *Object, fd: i32) callconv(.c) void {
    const object: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    defer _ = object.arena.reset(.retain_capacity);
    var buffer: [32_768]u8 = undefined;
    var fba = heap.FixedBufferAllocator.init(&buffer);
    var fallback_allocator = hyprwire.FallbackAllocator{
        .fba = &fba,
        .fallback = fba.allocator(),
        .fixed = object.arena.allocator(),
    };
    object.listener.vtable.myManagerV1Listener(
        object.listener.ptr,
        fallback_allocator.allocator(),
        .{ .send_message_fd = .{
            .message = fd,
        } },
    );
}

fn myManagerV1_method2(r: *Object, message: [*][*:0]const u8, message_len: u32) callconv(.c) void {
    const object: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    defer _ = object.arena.reset(.retain_capacity);
    var buffer: [32_768]u8 = undefined;
    var fba = heap.FixedBufferAllocator.init(&buffer);
    var fallback_allocator = hyprwire.FallbackAllocator{
        .fba = &fba,
        .fallback = fba.allocator(),
        .fixed = object.arena.allocator(),
    };
    object.listener.vtable.myManagerV1Listener(
        object.listener.ptr,
        fallback_allocator.allocator(),
        .{ .send_message_array = .{
            .message = fallback_allocator.allocator().dupe([*:0]const u8, message[0..message_len]) catch return,
        } },
    );
}

fn myManagerV1_method3(r: *Object, message: [*:0]u32) callconv(.c) void {
    const object: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    defer _ = object.arena.reset(.retain_capacity);
    var buffer: [32_768]u8 = undefined;
    var fba = heap.FixedBufferAllocator.init(&buffer);
    var fallback_allocator = hyprwire.FallbackAllocator{
        .fba = &fba,
        .fallback = fba.allocator(),
        .fixed = object.arena.allocator(),
    };
    object.listener.vtable.myManagerV1Listener(
        object.listener.ptr,
        fallback_allocator.allocator(),
        .{ .send_message_array_uint = .{
            .message = message,
        } },
    );
}

fn myManagerV1_method4(r: *Object, seq: u32) callconv(.c) void {
    const object: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    defer _ = object.arena.reset(.retain_capacity);
    var buffer: [32_768]u8 = undefined;
    var fba = heap.FixedBufferAllocator.init(&buffer);
    var fallback_allocator = hyprwire.FallbackAllocator{
        .fba = &fba,
        .fallback = fba.allocator(),
        .fixed = object.arena.allocator(),
    };
    object.listener.vtable.myManagerV1Listener(
        object.listener.ptr,
        fallback_allocator.allocator(),
        .{ .make_object = .{
            .seq = seq,
        } },
    );
}

pub const MyManagerV1Event = union(enum) {
    send_message: struct {
        message: [*:0]const u8,
    },
    send_message_fd: struct {
        message: i32,
    },
    send_message_array: struct {
        message: [][*:0]const u8,
    },
    send_message_array_uint: struct {
        message: [*:0]u32,
    },
    make_object: struct {
        seq: u32,
    },
};

pub const MyManagerV1Listener = hyprwire.Trait(.{
    .myManagerV1Listener = fn (mem.Allocator, MyManagerV1Event) void,
}, null);

pub const MyManagerV1Object = struct {
    object: *Object,
    listener: MyManagerV1Listener,
    arena: heap.ArenaAllocator,

    const Self = @This();

    pub fn init(gpa: mem.Allocator, listener: MyManagerV1Listener, object: *Object) !*Self {
        const self = try gpa.create(Self);
        self.* = .{
            .listener = listener,
            .object = object,
            .arena = heap.ArenaAllocator.init(gpa),
        };

        object.vtable.setData(object.ptr, self);

        try object.vtable.listen(object.ptr, gpa, 0, @ptrCast(&myManagerV1_method0));
        try object.vtable.listen(object.ptr, gpa, 1, @ptrCast(&myManagerV1_method1));
        try object.vtable.listen(object.ptr, gpa, 2, @ptrCast(&myManagerV1_method2));
        try object.vtable.listen(object.ptr, gpa, 3, @ptrCast(&myManagerV1_method3));
        try object.vtable.listen(object.ptr, gpa, 4, @ptrCast(&myManagerV1_method4));

        return self;
    }

    pub fn deinit(self: *Self, gpa: mem.Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
        self.object.vtable.deinit(self.object.ptr);
    }

    pub fn getObject(self: *Self) *Object {
        return self.object;
    }

    pub fn err(self: *Self, code: u32, message: []const u8) void {
        self.object.vtable.err(self.object.ptr, code, message);
    }

    pub fn setOnDeinit(self: *Self, @"fn": *const fn () void) void {
        self.object.vtable.setOnDeinit(self.object.ptr, @"fn");
    }

    pub fn sendSendMessage(self: *Self, gpa: mem.Allocator, message: [:0]const u8) !void {
        var args = try Args.init(gpa, .{message});
        defer args.deinit(gpa);
        _ = try self.object.vtable.call(self.object.ptr, gpa, 0, &args);
    }

    pub fn sendRecvMessageArrayUint(self: *Self, gpa: mem.Allocator, message: []const u32) !void {
        var args = try Args.init(gpa, .{message});
        defer args.deinit(gpa);
        _ = try self.object.vtable.call(self.object.ptr, gpa, 1, &args);
    }
};

fn myObjectV1_method0(r: *Object, message: [*:0]const u8) callconv(.c) void {
    const object: *MyObjectV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    defer _ = object.arena.reset(.retain_capacity);
    var buffer: [32_768]u8 = undefined;
    var fba = heap.FixedBufferAllocator.init(&buffer);
    var fallback_allocator = hyprwire.FallbackAllocator{
        .fba = &fba,
        .fallback = fba.allocator(),
        .fixed = object.arena.allocator(),
    };
    object.listener.vtable.myObjectV1Listener(
        object.listener.ptr,
        fallback_allocator.allocator(),
        .{ .send_message = .{
            .message = message,
        } },
    );
}

fn myObjectV1_method1(r: *Object, value: i32) callconv(.c) void {
    const object: *MyObjectV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    defer _ = object.arena.reset(.retain_capacity);
    var buffer: [32_768]u8 = undefined;
    var fba = heap.FixedBufferAllocator.init(&buffer);
    var fallback_allocator = hyprwire.FallbackAllocator{
        .fba = &fba,
        .fallback = fba.allocator(),
        .fixed = object.arena.allocator(),
    };
    object.listener.vtable.myObjectV1Listener(
        object.listener.ptr,
        fallback_allocator.allocator(),
        .{ .send_enum = .{
            .message = @enumFromInt(value),
        } },
    );
}

fn myObjectV1_method2(r: *Object) callconv(.c) void {
    const object: *MyObjectV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    defer _ = object.arena.reset(.retain_capacity);
    var buffer: [32_768]u8 = undefined;
    var fba = heap.FixedBufferAllocator.init(&buffer);
    var fallback_allocator = hyprwire.FallbackAllocator{
        .fba = &fba,
        .fallback = fba.allocator(),
        .fixed = object.arena.allocator(),
    };
    object.listener.vtable.myObjectV1Listener(
        object.listener.ptr,
        fallback_allocator.allocator(),
        .{ .destroy = .{} },
    );
}

pub const MyObjectV1Event = union(enum) {
    send_message: struct {
        message: [*:0]const u8,
    },
    send_enum: struct {
        message: spec.TestProtocolV1MyEnum,
    },
    destroy: struct {},
};

pub const MyObjectV1Listener = hyprwire.Trait(.{
    .myObjectV1Listener = fn (mem.Allocator, MyObjectV1Event) void,
}, null);

pub const MyObjectV1Object = struct {
    object: *Object,
    listener: MyObjectV1Listener,
    arena: heap.ArenaAllocator,

    const Self = @This();

    pub fn init(gpa: mem.Allocator, listener: MyObjectV1Listener, object: *Object) !*Self {
        const self = try gpa.create(Self);
        self.* = .{
            .object = object,
            .listener = listener,
            .arena = heap.ArenaAllocator.init(gpa),
        };

        object.vtable.setData(object.ptr, self);

        try object.vtable.listen(object.ptr, gpa, 0, @ptrCast(&myObjectV1_method0));
        try object.vtable.listen(object.ptr, gpa, 1, @ptrCast(&myObjectV1_method1));
        try object.vtable.listen(object.ptr, gpa, 2, @ptrCast(&myObjectV1_method2));

        return self;
    }

    pub fn deinit(self: *Self, gpa: mem.Allocator) void {
        self.arena.deinit();
        gpa.destroy(self);
        self.object.vtable.deinit(self.object.ptr);
    }

    pub fn setOnDeinit(self: *Self, @"fn": *const fn (*Self) void) void {
        self.object.vtable.setOnDeinit(self.object.ptr, @"fn");
    }

    pub fn err(self: *Self, gpa: mem.Allocator, code: u32, message: [:0]const u8) !void {
        try self.object.vtable.err(self.object.ptr, gpa, code, message);
    }

    pub fn sendSendMessage(self: *Self, gpa: mem.Allocator, message: [:0]const u8) !void {
        var args = try Args.init(gpa, .{message});
        defer args.deinit(gpa);
        _ = try self.object.vtable.call(self.object.ptr, gpa, 0, &args);
    }
};

pub const TestProtocolV1Listener = hyprwire.Trait(.{
    .bind = fn (*Object) void,
}, null);

const test_protocol_v1_spec = TestProtocolV1ProtocolSpec{};

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

    pub fn protocol(self: *Self) ProtocolSpec {
        _ = self;
        return ProtocolSpec.from(&test_protocol_v1_spec);
    }

    pub fn implementation(
        self: *Self,
        gpa: mem.Allocator,
    ) ![]*ServerObjectImplementation {
        const impls = try gpa.alloc(*ServerObjectImplementation, 2);
        errdefer gpa.free(impls);

        impls[0] = try gpa.create(ServerObjectImplementation);
        errdefer gpa.destroy(impls[0]);
        impls[0].* = .{
            .context = self.listener.ptr,
            .object_name = "my_manager_v1",
            .version = self.version,
            .onBind = self.listener.vtable.bind,
        };

        impls[1] = try gpa.create(ServerObjectImplementation);
        errdefer gpa.destroy(impls[1]);
        impls[1].* = .{
            .context = self.listener.ptr,
            .object_name = "my_object_v1",
            .version = self.version,
        };

        return impls;
    }
};
