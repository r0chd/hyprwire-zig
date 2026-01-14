const std = @import("std");
const types = @import("../implementation/types.zig");

const Message = @import("../message/messages/root.zig");
const ClientSocket = @import("ClientSocket.zig");
const WireObject = @import("../implementation/WireObject.zig");
const Method = types.Method;

interface: WireObject,
client: ?*ClientSocket,

const Self = @This();

pub fn init(client: *ClientSocket) Self {
    return .{
        .interface = .{
            .clientSockFn = Self.clientSockFn,
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

pub fn methodsOut(self: *const Self) []const Method {
    if (self.interface.spec) |spec| {
        return spec.c2s();
    } else {
        return &.{};
    }
}

pub fn methodsIn(self: *const Self) []const Method {
    if (self.interface.spec) |spec| {
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
