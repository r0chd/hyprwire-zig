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

    pub fn sendSendMessage(self: *Self, gpa: mem.Allocator, message: [:0]const u8) !void {
        const args = struct {
            message: [:0]const u8,
        }{ .message = message };
        _ = args;

        _ = try self.object.vtable.call(self.object.ptr, gpa, 0);
    }

    pub fn sendSendMessageFd(self: *Self, gpa: mem.Allocator, message: i32) !void {
        const args = struct {
            message: i32,
        }{ .message = message };
        _ = args;

        _ = try self.object.vtable.call(self.object.ptr, gpa, 1);
    }

    pub fn sendSendMessageArray(self: *Self, gpa: mem.Allocator, message: []const [:0]const u8) !void {
        const args = struct {
            message: []const [:0]const u8,
        }{ .message = message };
        _ = args;

        _ = try self.object.vtable.call(self.object.ptr, gpa, 2);
    }

    pub fn sendSendMessageArrayUint(self: *Self, gpa: mem.Allocator, message: []const i32) !void {
        const args = struct {
            message: []const i32,
        }{ .message = message };
        _ = args;

        _ = try self.object.vtable.call(self.object.ptr, gpa, 3);
    }

    pub fn sendMakeObject(self: *Self, gpa: mem.Allocator) ?Object {
        const args = struct {}{};
        _ = args;

        const id = self.object.vtable.call(self.object.ptr, gpa, 4) catch return null;
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

    pub fn sendSendMessage(self: *Self, gpa: mem.Allocator, message: [:0]const u8) !void {
        const args = struct {
            message: [:0]const u8,
        }{ .message = message };
        _ = args;

        _ = try self.object.vtable.call(self.object.ptr, gpa, 0);
    }

    pub fn sendSendEnum(self: *Self, gpa: mem.Allocator, message: spec.TestProtocolV1MyEnum) !void {
        const args = struct {
            message: spec.TestProtocolV1MyEnum,
        }{ .message = message };
        _ = args;

        _ = try self.object.vtable.call(self.object.ptr, gpa, 1);
    }

    pub fn sendDestroy(self: *Self, gpa: mem.Allocator) !void {
        const args = struct {}{};
        _ = args;

        _ = try self.object.vtable.call(self.object.ptr, gpa, 2);
        self.object.destroy();
    }

    pub fn setSendMessage(self: *Self, callback: *const fn (*Self, [:0]const u8) void) void {
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
