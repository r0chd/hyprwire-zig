const std = @import("std");
const types = @import("../implementation/types.zig");
const messages = @import("../message/messages/root.zig");

const mem = std.mem;

const FatalErrorMessage = @import("../message/messages/FatalProtocolError.zig");
const ServerSocket = @import("ServerSocket.zig");
const ServerClient = @import("ServerClient.zig");
const WireObject = @import("../implementation/WireObject.zig");
const Object = @import("../implementation/Object.zig");
const Message = messages.Message;
const Method = types.Method;

client: ?*ServerClient,
spec: ?*types.ProtocolObjectSpec = null,
data: ?*anyopaque = null,
listeners: std.ArrayList(*const fn (*anyopaque) void) = .empty,
on_deinit: ?*const fn () void = null,
id: u32 = 0,
version: u32 = 0,
seq: u32 = 1,
protocol_name: []const u8 = "",

const Self = @This();

pub fn init(client: *ServerClient) Self {
    return .{
        .client = client,
    };
}

pub fn wireObject(self: *Self) WireObject {
    return .{
        .ptr = self,
        .vtable = &.{
            .getListeners = Self.getListeners,
            .methodsOut = Self.methodsOut,
            .methodsIn = Self.methodsIn,
            .errd = Self.errd,
            .sendMessage = Self.sendMessage,
            .server = Self.server,
        },
    };
}

pub fn object(self: *Self) Object {
    return .{
        .ptr = self,
        .vtable = &.{
            .getData = Self.getData,
            .setData = Self.setData,
            .setOnDeinit = Self.setOnDeinit,
            .getOnDeinit = Self.getOnDeinit,
            .err = Self.err,
            .deinit = Self.deinit,
        },
    };
}

pub fn methodsOut(ptr: *anyopaque) []const Method {
    const self: *const Self = @ptrCast(@alignCast(ptr));
    if (self.spec) |spec| {
        return spec.s2c();
    } else {
        return &.{};
    }
}

pub fn methodsIn(ptr: *anyopaque) []const Method {
    const self: *const Self = @ptrCast(@alignCast(ptr));
    if (self.spec) |spec| {
        return spec.c2s();
    } else {
        return &.{};
    }
}

pub fn errd(ptr: *anyopaque) void {
    const self: *const Self = @ptrCast(@alignCast(ptr));
    if (self.client) |client| {
        client.@"error" = true;
    }
}

pub fn getListeners(ptr: *anyopaque) std.ArrayList(*const fn (*anyopaque) void) {
    const self: *const Self = @ptrCast(@alignCast(ptr));
    return self.listeners;
}

pub fn sendMessage(ptr: *anyopaque, gpa: mem.Allocator, message: Message) !void {
    const self: *const Self = @ptrCast(@alignCast(ptr));
    if (self.client) |client| {
        client.sendMessage(gpa, message);
    }
}

pub fn server(ptr: *anyopaque) bool {
    _ = ptr;
    return true;
}

pub fn serverSockFn(ptr: *const WireObject) ?*ServerSocket {
    const self: *const Self = @fieldParentPtr("interface", ptr);
    if (self.client) |client| {
        if (client.server) |srv| {
            return srv;
        }
    }

    return null;
}

pub fn getServerSock(ptr: *anyopaque) ?*ServerSocket {
    const self: *const Self = @ptrCast(@alignCast(ptr));
    if (self.client) |client| {
        if (client.server) |srv| {
            return srv;
        }
    }
    return null;
}

pub fn getData(ptr: *anyopaque) ?*anyopaque {
    const self: *const Self = @ptrCast(@alignCast(ptr));
    return self.data;
}

pub fn setData(ptr: *anyopaque, data: ?*anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.data = data;
}

pub fn setOnDeinit(ptr: *anyopaque, cb: *const fn () void) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.on_deinit = cb;
}

pub fn getOnDeinit(ptr: *anyopaque) ?*const fn () void {
    const self: *const Self = @ptrCast(@alignCast(ptr));
    return self.on_deinit;
}

pub fn err(ptr: *anyopaque, gpa: mem.Allocator, id: u32, message: [:0]const u8) !void {
    var self: *Self = @ptrCast(@alignCast(ptr));
    var msg = try FatalErrorMessage.init(gpa, self.id, id, message);
    defer msg.deinit(gpa);
    if (self.client) |client| {
        client.sendMessage(gpa, Message.from(&msg));
    }

    var wire_object = self.wireObject();
    wire_object.vtable.errd(wire_object.ptr);
}

pub fn deinit(ptr: *anyopaque) void {
    var self: *Self = @ptrCast(@alignCast(ptr));
    var obj = self.object();
    if (obj.getOnDeinit()) |onDeinit| {
        onDeinit();
    }
}

test {
    const alloc = std.testing.allocator;
    {
        var client = try ServerClient.init(1);
        var self = Self.init(&client);

        const obj = self.object();
        try obj.err(alloc, 1, "anfea");

        var wire_object = self.wireObject();
        wire_object.vtable.errd(wire_object.ptr);
        var listeners = wire_object.vtable.getListeners(wire_object.ptr);
        listeners.deinit(alloc);

        const methods_in = wire_object.vtable.methodsIn(wire_object.ptr);
        _ = methods_in;

        const methods_out = wire_object.vtable.methodsOut(wire_object.ptr);
        _ = methods_out;

        var hello = messages.Hello.init();
        try wire_object.vtable.sendMessage(wire_object.ptr, alloc, Message.from(&hello));
        _ = wire_object.vtable.server(wire_object.ptr);
    }
}
