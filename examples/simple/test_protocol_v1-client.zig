const std = @import("std");
const spec = @import("test_protocol_v1-spec.zig");
const hyprwire = @import("hyprwire");

const mem = std.mem;

const Object = hyprwire.types.Object;
const ProtocolSpec = hyprwire.types.ProtocolSpec;

const ClientObjectImplementation = hyprwire.types.client_impl.ClientObjectImplementation;

pub const MyManagerV1Object = struct {
    object: Object,
    listeners: struct {
        send_message: ?*const fn (*Self, [:0]const u8) void = null,
        recv_message_array_uint: ?*const fn (*Self, []u32) void = null,
    },

    const Self = @This();

    pub fn init(object: Object) Self {
        return .{
            .object = object,
            .listeners = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn sendSendMessage(self: *Self, message: [:0]const u8) void {
        _ = self.object.vtable.call(self.object.ptr, 0, @constCast(&.{message}));
    }

    pub fn sendSendMessageFd(self: *Self, message: i32) void {
        _ = self.object.vtable.call(self.object.ptr, 1, @constCast(&.{message}));
    }

    pub fn sendSendMessageArray(self: *Self, message: []const [:0]const u8) void {
        _ = self.object.vtable.call(self.object.ptr, 2, @constCast(&.{message}));
    }

    pub fn sendSendMessageArrayUint(self: *Self, message: []const i32) void {
        _ = self.object.vtable.call(self.object.ptr, 3, @constCast(&.{message}));
    }

    pub fn sendMakeObject(self: *Self) ?Object {
        const id = self.object.vtable.call(self.object.ptr, 4, @constCast(&.{}));
        if (self.object.vtable.clientSock(self.object.ptr)) |sock| {
            return sock.objectForId(id);
        }

        return null;
    }

    pub fn setSendMessage(self: *Self, @"fn": *const fn (*Self, [:0]const u8) void) void {
        self.listeners.send_message = @"fn";
    }

    pub fn setRecvMessageArrayUint(self: *Self, @"fn": *const fn (*Self, []u32) void) void {
        self.listeners.recv_message_array_uint = @"fn";
    }

    pub fn dispatch(
        self: *Self,
        opcode: u16,
        args: anytype,
    ) void {
        switch (opcode) {
            0 => if (self.listeners.send_message) |cb|
                cb(self, args[0]),
            1 => if (self.listeners.recv_message_array_uint) |cb|
                cb(self, args[0]),
            else => {},
        }
    }
};

pub const MyObjectV1Object = struct {
    object: Object,
    listeners: Listeners = .{},

    const Self = @This();

    const Listeners = struct {
        send_message: ?*const fn (*Self, [:0]const u8) void = null,
    };

    pub fn init(object: Object) Self {
        return .{
            .object = object,
            .listeners = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn sendSendMessage(self: *Self, message: [:0]const u8) void {
        _ = self.object.vtable.call(self.object.ptr, 0, @constCast(&.{message}));
    }

    pub fn sendSendEnum(self: *Self, message: spec.TestProtocolV1MyEnum) void {
        _ = self.object.vtable.call(self.object.ptr, 1, @constCast(&.{@intFromEnum(message)}));
    }

    pub fn sendDestroy(self: *Self) void {
        _ = self.object.vtable.call(self.object.ptr, 2, @constCast(&.{}));
        self.object.destroy();
    }

    pub fn setSendMessage(
        self: *Self,
        callback: *const fn (*Self, [:0]const u8) void,
    ) void {
        self.listeners.send_message = callback;
    }

    pub fn dispatch(
        self: *Self,
        opcode: u16,
        args: anytype,
    ) void {
        switch (opcode) {
            0 => if (self.listeners.send_message) |cb|
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

    pub fn protocol(self: *Self) ProtocolSpec {
        _ = self;
        return ProtocolSpec.from(&spec.protocol);
    }

    pub fn implementation(
        self: *Self,
        gpa: mem.Allocator,
    ) ![]*ClientObjectImplementation {
        var impls = [_]*ClientObjectImplementation{
            try gpa.create(ClientObjectImplementation),
            try gpa.create(ClientObjectImplementation),
        };

        impls[0].* = .{
            .object_name = "my_manager_v1",
            .version = self.version,
        };
        impls[1].* = .{
            .object_name = "my_object_v1",
            .version = self.version,
        };

        return &impls;
    }
};
