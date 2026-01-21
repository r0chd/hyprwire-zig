const std = @import("std");
const spec = @import("test_protocol_v1-spec.zig");
const hyprwire = @import("hyprwire");

const mem = std.mem;
const fmt = std.fmt;

const Object = hyprwire.types.Object;
const ProtocolSpec = hyprwire.types.ProtocolSpec;
const Args = hyprwire.types.Args;

const ClientObjectImplementation = hyprwire.types.client_impl.ClientObjectImplementation;

fn myManagerV1_method0(r: *Object, message: [*:0]const u8) callconv(.c) void {
    const object: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    if (object.listeners.send_message) |cb| {
        cb(message);
    }
}

fn myManagerV1_method1(r: *Object, message: [*]u32) void {
    const object: *MyManagerV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    if (object.listeners.recv_message_array_uint) |cb| {
        cb(message);
    }
}

pub const MyManagerV1Object = struct {
    object: *Object,
    listeners: struct {
        send_message: ?*const fn ([*:0]const u8) void = null,
        recv_message_array_uint: ?*const fn ([*]u32) void = null,
    } = .{},

    const Self = @This();

    pub fn init(gpa: mem.Allocator, object: *Object) !*Self {
        const self = try gpa.create(Self);
        self.* = Self{
            .object = object,
        };

        object.vtable.setData(object.ptr, self);
        try object.vtable.listen(object.ptr, gpa, 0, @ptrCast(&myManagerV1_method0));
        try object.vtable.listen(object.ptr, gpa, 1, @ptrCast(&myManagerV1_method1));

        return self;
    }

    pub fn deinit(self: *Self, gpa: mem.Allocator) void {
        gpa.destroy(self);
    }

    pub fn sendSendMessage(self: *Self, gpa: mem.Allocator, message: [:0]const u8) !void {
        var args = try Args.init(gpa, .{message});
        defer args.deinit(gpa);
        _ = try self.object.vtable.call(self.object.ptr, gpa, 0, &args);
    }

    pub fn sendSendMessageFd(self: *Self, gpa: mem.Allocator, message: i32) !void {
        var args = try Args.init(gpa, .{message});
        defer args.deinit(gpa);
        _ = try self.object.vtable.call(self.object.ptr, gpa, 1, &args);
    }

    pub fn sendSendMessageArray(self: *Self, gpa: mem.Allocator, message: []const [:0]const u8) !void {
        var args = try Args.init(gpa, .{message});
        defer args.deinit(gpa);
        _ = try self.object.vtable.call(self.object.ptr, gpa, 2, &args);
    }

    pub fn sendSendMessageArrayUint(self: *Self, gpa: mem.Allocator, message: []const u32) !void {
        var args = try Args.init(gpa, .{message});
        defer args.deinit(gpa);
        _ = try self.object.vtable.call(self.object.ptr, gpa, 3, &args);
    }

    pub fn sendMakeObject(self: *Self, gpa: mem.Allocator) ?Object {
        var args = Args.init(gpa, .{}) catch return null;
        defer args.deinit(gpa);
        const id = self.object.vtable.call(self.object.ptr, gpa, 4, &args) catch return null;
        if (self.object.vtable.clientSock(self.object.ptr)) |sock| {
            return sock.objectForId(id);
        }

        return null;
    }

    pub fn setSendMessage(self: *Self, @"fn": *const fn ([*:0]const u8) void) void {
        self.listeners.send_message = @"fn";
    }

    pub fn setRecvMessageArrayUint(self: *Self, @"fn": *const fn ([]u32) void) void {
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

fn myObjectV1_method0(r: *Object, message: [*:0]const u8) callconv(.c) void {
    const object: *MyObjectV1Object = @ptrCast(@alignCast(r.vtable.getData(r.ptr)));
    if (object.listeners.send_message) |cb| {
        cb(message);
    }
}

pub const MyObjectV1Object = struct {
    object: *Object,
    listeners: struct {
        send_message: ?*const fn ([*:0]const u8) void = null,
    } = .{},

    const Self = @This();

    pub fn init(gpa: mem.Allocator, object: *Object) !*Self {
        const self = try gpa.create(Self);
        self.* = .{
            .object = object,
        };

        object.vtable.setData(object.ptr, self);
        try object.vtable.listen(object.ptr, gpa, 0, @ptrCast(&myObjectV1_method0));

        return self;
    }

    pub fn deinit(self: *Self, gpa: mem.Allocator) void {
        gpa.destroy(self);
    }

    pub fn sendSendMessage(self: *Self, gpa: mem.Allocator, message: [:0]const u8) !void {
        var args = try Args.init(gpa, .{message});
        defer args.deinit(gpa);
        _ = try self.object.vtable.call(self.object.ptr, gpa, 0, &args);
    }

    pub fn sendSendEnum(self: *Self, gpa: mem.Allocator, message: spec.TestProtocolV1MyEnum) !void {
        var args = try Args.init(gpa, .{message});
        defer args.deinit(gpa);
        _ = try self.object.vtable.call(self.object.ptr, gpa, 1, &args);
    }

    pub fn sendDestroy(self: *Self, gpa: mem.Allocator) !void {
        var args = try Args.init(gpa, .{});
        defer args.deinit(gpa);
        _ = try self.object.vtable.call(self.object.ptr, gpa, 2, &args);
        self.object.destroy();
    }

    pub fn setSendMessage(self: *Self, callback: *const fn ([*:0]const u8) void) void {
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
        const impls = try gpa.alloc(*ClientObjectImplementation, 2);
        errdefer gpa.free(impls);

        impls[0] = try gpa.create(ClientObjectImplementation);
        errdefer gpa.destroy(impls[0]);
        impls[0].* = .{
            .object_name = "my_manager_v1",
            .version = self.version,
        };

        impls[1] = try gpa.create(ClientObjectImplementation);
        errdefer gpa.destroy(impls[1]);
        impls[1].* = .{
            .object_name = "my_object_v1",
            .version = self.version,
        };

        return impls;
    }
};
