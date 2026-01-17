const hyprwire = @import("hyprwire");
const std = @import("std");
const spec = @import("test_protocol_v1-spec.zig");

const mem = std.mem;

const ProtocolSpec = hyprwire.types.ProtocolSpec;
const Object = hyprwire.types.Object;
const ServerObjectImplementation = hyprwire.types.server_impl.ServerObjectImplementation;
const TestProtocolV1ProtocolSpec = spec.TestProtocolV1ProtocolSpec;

fn myManagerV1_method0(r: Object, message: [:0]const u8) void {
    const self: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    if (self.listeners.send_message) |@"fn"| {
        @"fn"(self, message);
    }
}

fn myManagerV1_method1(r: Object, message: i32) void {
    const self: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    if (self.listeners.send_message_fd) |@"fn"| {
        @"fn"(self, message);
    }
}

fn myManagerV1_method2(r: Object, message: [][:0]const u8) void {
    const self: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    if (self.listeners.send_message_array) |@"fn"| {
        @"fn"(self, message);
    }
}

fn myManagerV1_method3(r: Object, message: []u32) void {
    const self: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    if (self.listeners.send_message_array_uint) |@"fn"| {
        @"fn"(self, message);
    }
}

fn myManagerV1_method4(r: Object, seq: u32) void {
    const self: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    if (self.listeners.make_object) |@"fn"| {
        @"fn"(self, seq);
    }
}

pub const MyManagerV1Object = struct {
    object: Object,
    listeners: struct {
        send_message: ?*const fn (*Self, [:0]const u8) void = null,
        send_message_fd: ?*const fn (*Self) void = null,
        send_message_array: ?*const fn (*Self, [][:0]const u8) void = null,
        send_message_array_uint: ?*const fn (*Self, []u32) void = null,
        make_object: ?*const fn (*Self, i32) void = null,
    },

    const Self = @This();

    pub fn init(gpa: mem.Allocator, object: Object) !*Self {
        const self = try gpa.create(Self);
        self.* = .{
            .object = object,
            .listeners = .{},
        };

        object.vtable.setData(object.ptr, self);

        object.vtable.listen(object.ptr, 0, myManagerV1_method0);
        object.vtable.listen(object.ptr, 1, myManagerV1_method1);
        object.vtable.listen(object.ptr, 2, myManagerV1_method2);
        object.vtable.listen(object.ptr, 3, myManagerV1_method3);
        object.vtable.listen(object.ptr, 4, myManagerV1_method4);

        return self;
    }

    pub fn deinit(self: *Self, gpa: mem.Allocator) void {
        gpa.destroy(self);
        self.object.vtable.deinit(self.object.ptr);
    }

    pub fn getObject(self: *Self) Object {
        return self.object;
    }

    pub fn err(self: *Self, code: u32, message: []const u8) void {
        self.object.vtable.err(self.object.ptr, code, message);
    }

    pub fn sendSendMessage(self: *Self, message: []const u8) void {
        self.object.vtable.call(self, 0, message);
    }

    pub fn sendRecvMessageArrayUint(self: *Self, message: []i32) void {
        self.object.vtable.call(self, 1, message);
    }

    pub fn setSendMessage(self: *Self, @"fn": *const fn (*Self, []const u8) void) void {
        self.listeners.send_message = @"fn";
    }

    pub fn setSendMessageFd(self: *Self, @"fn": *const fn (*Self) void) void {
        self.listeners.send_message_fd = @"fn";
    }

    pub fn setSendMessageArray(self: *Self, @"fn": *const fn (*Self, [][]const u8) void) void {
        self.listeners.send_message_array = @"fn";
    }

    pub fn setSendMessageArrayUint(self: *Self, @"fn": *const fn (*Self, [][]i32) void) void {
        self.listeners.send_message_array_uint = @"fn";
    }

    pub fn setMakeObject(self: *Self, @"fn": *const fn (*Self, i32) void) void {
        self.listeners.make_object = @"fn";
    }
};

fn myObjectV1_method0(r: Object, message: [:0]const u8) void {
    const self: *MyObjectV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    if (self.listeners.send_message) |@"fn"| {
        @"fn"(self, message);
    }
}

fn myObjectV1_method1(r: Object, message: i32) void {
    const self: *MyObjectV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    if (self.listeners.send_enum) |@"fn"| {
        @"fn"(self, message);
    }
}

fn myObjectV1_method2(r: Object, message: [][:0]const u8) void {
    const self: *MyObjectV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    if (self.listeners.destroy) |@"fn"| {
        @"fn"(self, message);
    }
}

pub const MyObjectV1Object = struct {
    object: Object,
    listeners: struct {
        send_message: ?*const fn (*Self, []const u8) void = null,
        send_enum: ?*const fn (*Self, spec.TestProtocolV1MyEnum) void = null,
        destroy: ?*const fn (*Self) void = null,
    },

    const Self = @This();

    pub fn init(gpa: mem.Allocator, object: Object) !Self {
        const self = try gpa.create(Self);
        self.* = .{
            .object = object,
            .listeners = .{},
        };

        object.vtable.setData(object.ptr, self);

        object.vtable.listen(object.ptr, 0, myObjectV1_method0);
        object.vtable.listen(object.ptr, 1, myObjectV1_method1);
        object.vtable.listen(object.ptr, 2, myObjectV1_method2);

        return .{
            .object = object,
            .listeners = .{},
        };
    }

    pub fn deinit(self: *Self, gpa: mem.Allocator) Self {
        gpa.destroy(self);
        self.object.vtable.deinit(self.object.ptr);
    }

    pub fn setOnDeinit(self: *Self, @"fn": *const fn (*Self) void) void {
        self.object.vtable.setOnDeinit(self.object.ptr, @"fn");
    }

    pub fn err(self: *Self, code: u32, message: []const u8) void {
        self.object.vtable.err(self.object.ptr, code, message);
    }

    pub fn sendSendMessage(self: *Self, message: []const u8) void {
        self.object.vtable.call(self.object.ptr, 0, message);
    }

    pub fn setSendMessage(self: *Self, @"fn": *const fn (*Self, []const u8) void) void {
        self.listeners.send_message = @"fn";
    }

    pub fn setSendEnum(self: *Self, @"fn": *const fn (*Self, []u32) void) void {
        self.listeners.send_enum = @"fn";
    }

    pub fn setDeinit(self: *Self, @"fn": *const fn (*Self) void) void {
        self.listeners.destroy = @"fn";
    }
};

const test_protocol_v1_spec = TestProtocolV1ProtocolSpec{};

pub const TestProtocolV1Impl = struct {
    version: u32,
    bind_fn: *const fn (Object) void,

    const Self = @This();

    pub fn init(
        version: u32,
        bind_fn: *const fn (Object) void,
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
        var impls = [_]*ServerObjectImplementation{
            try gpa.create(ServerObjectImplementation),
            try gpa.create(ServerObjectImplementation),
        };

        impls[0].* = .{
            .object_name = "my_manager_v1",
            .version = self.version,
            .onBind = self.bind_fn,
        };
        impls[1].* = .{
            .object_name = "my_object_v1",
            .version = self.version,
        };

        return &impls;
    }
};
