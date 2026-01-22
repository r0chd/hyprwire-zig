const hyprwire = @import("hyprwire");
const std = @import("std");
const spec = @import("test_protocol_v1-spec.zig");

const mem = std.mem;

const ProtocolSpec = hyprwire.types.ProtocolSpec;
const Object = hyprwire.types.Object;
const ServerObjectImplementation = hyprwire.types.server_impl.ServerObjectImplementation;
const TestProtocolV1ProtocolSpec = spec.TestProtocolV1ProtocolSpec;
const Args = hyprwire.types.Args;

fn myManagerV1_method0(r: *Object, message: [*:0]const u8) callconv(.c) void {
    const self: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    if (self.listeners.send_message) |@"fn"| {
        @"fn"(message);
    }
}

fn myManagerV1_method1(r: *Object, message: i32) callconv(.c) void {
    const self: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    if (self.listeners.send_message_fd) |@"fn"| {
        @"fn"(message);
    }
}

fn myManagerV1_method2(r: *Object, message: [*:null]?[*:0]const u8) callconv(.c) void {
    const self: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    if (self.listeners.send_message_array) |@"fn"| {
        @"fn"(message);
    }
}

fn myManagerV1_method3(r: *Object, message: [*:0]u32) callconv(.c) void {
    const self: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    if (self.listeners.send_message_array_uint) |@"fn"| {
        @"fn"(message);
    }
}

fn myManagerV1_method4(r: *Object, seq: u32) callconv(.c) void {
    const self: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    if (self.listeners.make_object) |@"fn"| {
        @"fn"(seq);
    }
}

pub const MyManagerV1Object = struct {
    object: *Object,
    listeners: struct {
        send_message: ?*const fn ([*:0]const u8) void = null,
        send_message_fd: ?*const fn (i32) void = null,
        send_message_array: ?*const fn ([*:null]?[*:0]const u8) void = null,
        send_message_array_uint: ?*const fn ([*:0]u32) void = null,
        make_object: ?*const fn (u32) void = null,
    } = .{},

    const Self = @This();

    pub fn init(gpa: mem.Allocator, object: *Object) !*Self {
        const self = try gpa.create(Self);
        self.* = .{
            .object = object,
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

    pub fn setSendMessage(self: *Self, @"fn": *const fn ([*:0]const u8) void) void {
        self.listeners.send_message = @"fn";
    }

    pub fn setSendMessageFd(self: *Self, @"fn": *const fn (i32) void) void {
        self.listeners.send_message_fd = @"fn";
    }

    pub fn setSendMessageArray(self: *Self, @"fn": *const fn ([*:null]?[*:0]const u8) void) void {
        self.listeners.send_message_array = @"fn";
    }

    pub fn setSendMessageArrayUint(self: *Self, @"fn": *const fn ([*:0]u32) void) void {
        self.listeners.send_message_array_uint = @"fn";
    }

    pub fn setMakeObject(self: *Self, @"fn": *const fn (u32) void) void {
        self.listeners.make_object = @"fn";
    }
};

fn myObjectV1_method0(r: *Object, message: [*:0]const u8) callconv(.c) void {
    const self: *MyObjectV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    if (self.listeners.send_message) |@"fn"| {
        @"fn"(message);
    }
}

fn myObjectV1_method1(r: *Object, message: i32) callconv(.c) void {
    const self: *MyObjectV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    if (self.listeners.send_enum) |@"fn"| {
        @"fn"(@enumFromInt(message));
    }
}

fn myObjectV1_method2(r: *Object) callconv(.c) void {
    const self: *MyObjectV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    if (self.listeners.destroy) |@"fn"| {
        @"fn"();
    }
}

pub const MyObjectV1Object = struct {
    object: *Object,
    listeners: struct {
        send_message: ?*const fn ([*:0]const u8) void = null,
        send_enum: ?*const fn (spec.TestProtocolV1MyEnum) void = null,
        destroy: ?*const fn () void = null,
    },

    const Self = @This();

    pub fn init(gpa: mem.Allocator, object: *Object) !*Self {
        const self = try gpa.create(Self);
        self.* = .{
            .object = object,
            .listeners = .{},
        };

        object.vtable.setData(object.ptr, self);

        try object.vtable.listen(object.ptr, gpa, 0, @ptrCast(&myObjectV1_method0));
        try object.vtable.listen(object.ptr, gpa, 1, @ptrCast(&myObjectV1_method1));
        try object.vtable.listen(object.ptr, gpa, 2, @ptrCast(&myObjectV1_method2));

        return self;
    }

    pub fn deinit(self: *Self, gpa: mem.Allocator) Self {
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

    pub fn setSendMessage(self: *Self, @"fn": *const fn ([*:0]const u8) void) void {
        self.listeners.send_message = @"fn";
    }

    pub fn setSendEnum(self: *Self, @"fn": *const fn (spec.TestProtocolV1MyEnum) void) void {
        self.listeners.send_enum = @"fn";
    }

    pub fn setDeinit(self: *Self, @"fn": *const fn () void) void {
        self.listeners.destroy = @"fn";
    }
};

const test_protocol_v1_spec = TestProtocolV1ProtocolSpec{};

pub const TestProtocolV1Impl = struct {
    version: u32,
    bind_fn: *const fn (*Object, mem.Allocator) void,

    const Self = @This();

    pub fn init(
        version: u32,
        bind_fn: *const fn (*Object, mem.Allocator) void,
    ) Self {
        return .{
            .version = version,
            .bind_fn = bind_fn,
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
            .object_name = "my_manager_v1",
            .version = self.version,
            .onBind = self.bind_fn,
        };

        impls[1] = try gpa.create(ServerObjectImplementation);
        errdefer gpa.destroy(impls[1]);
        impls[1].* = .{
            .object_name = "my_object_v1",
            .version = self.version,
        };

        return impls;
    }
};
