const std = @import("std");
const types = @import("../implementation/types.zig");
const ServerSocket = @import("../server/ServerSocket.zig");

const Message = @import("../message/messages/root.zig");
const ClientSocket = @import("ClientSocket.zig");
const WireObject = @import("../implementation/WireObject.zig");
const Object = @import("../implementation/Object.zig");
const Method = types.Method;

interface: WireObject,
client: ?*ClientSocket,
spec: ?*types.ProtocolObjectSpec = null,

const Self = @This();

pub fn init(client: *ClientSocket) Self {
    return .{
        .interface = .{
            .methodsInFn = Self.methodsIn,
            .methodsOutFn = Self.methodsOut,
        },
        .client = client,
    };
}

pub fn clientSockFn(ptr: *const WireObject) ?*ClientSocket {
    const self: *const Self = @fieldParentPtr("interface", ptr);
    if (self.client) |client| {
        if (client.server) |server| {
            return server;
        }
    }

    return null;
}

pub fn object(self: *Self) Object {
    return .{
        .ptr = self,
        .vtable = &.{
            .getClientSock = Self.getClientSock,
            .getServerSock = Self.getServerSock,
            .getData = Self.getData,
            .setData = Self.setData,
            .err = Self.objectErr,
            .deinit = Self.objectDeinit,
            .setOnDeinit = Self.setOnDeinit,
            .getOnDeinit = Self.getOnDeinit,
        },
    };
}

pub fn getClientSock(ptr: *anyopaque) ?*ClientSocket {
    const self: *const Self = @ptrCast(@alignCast(ptr));
    return self.client;
}

pub fn getServerSock(ptr: *anyopaque) ?*ServerSocket {
    _ = ptr;
    return null;
}

pub fn getData(ptr: *anyopaque) ?*anyopaque {
    const self: *const Self = @ptrCast(@alignCast(ptr));
    return self.interface.data;
}

pub fn setData(ptr: *anyopaque, data: ?*anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.interface.data = data;
}

pub fn objectErr(ptr: *anyopaque, id: u32, message: [:0]const u8) void {
    _ = ptr;
    _ = id;
    _ = message;
    // Default implementation does nothing
}

pub fn objectDeinit(ptr: *anyopaque, id: u32, message: [:0]const u8) void {
    _ = id;
    _ = message;
    const self: *const Self = @ptrCast(@alignCast(ptr));
    if (self.interface.on_deinit) |onDeinit| {
        onDeinit();
    }
}

pub fn setOnDeinit(ptr: *anyopaque, cb: *const fn () void) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.interface.on_deinit = cb;
}

pub fn getOnDeinit(ptr: *anyopaque) ?*const fn () void {
    const self: *const Self = @ptrCast(@alignCast(ptr));
    return self.interface.on_deinit;
}

pub fn methodsOut(ptr: *const WireObject) []const Method {
    const self: *const Self = @fieldParentPtr("interface", ptr);
    if (self.spec) |spec| {
        return spec.c2s();
    } else {
        return &.{};
    }
}

pub fn methodsIn(ptr: *const WireObject) []const Method {
    const self: *const Self = @fieldParentPtr("interface", ptr);
    if (self.spec) |spec| {
        return spec.s2c();
    } else {
        return &.{};
    }
}

pub fn errd(self: *Self) void {
    if (self.client) |client| {
        client.@"error" = true;
    }
}

pub fn sendMessage(self: *Self, message: Message) void {
    if (self.client) |client| {
        client.sendMessage(message);
    }
}
