const std = @import("std");
const types = @import("../implementation/types.zig");

const Message = @import("../message/messages/root.zig");
const ClientSocket = @import("ClientSocket.zig");
const WireObject = @import("../implementation/WireObject.zig");
const Method = types.Method;

base: WireObject,
client: ?*ClientSocket,

const Self = @This();

pub fn init(client: *ClientSocket) Self {
    return .{
        .base = .{},
        .client = client,
    };
}

pub fn methodsOut(self: *const Self) []const Method {
    if (self.base.spec) |spec| {
        return spec.c2s();
    } else {
        return &.{};
    }
}

pub fn methodsIn(self: *const Self) []const Method {
    if (self.base.spec) |spec| {
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

pub fn sendMessage(self: *Self, message: *const Message) void {
    if (self.client) |client| {
        client.sendMessage(message);
    }
}
