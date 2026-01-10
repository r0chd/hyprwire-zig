const std = @import("std");
const types = @import("../implementation/types.zig");

const mem = std.mem;

const ServerClient = @import("ServerClient.zig");
const WireObject = @import("../implementation/WireObject.zig");
const Method = types.Method;

base: WireObject,
client: ?*ServerClient,

const Self = @This();

pub fn init(client: *ServerClient) Self {
    return .{
        .base = .{},
        .client = client,
    };
}

pub fn methodsOut(self: *const Self) []const Method {
    if (self.base.spec) |spec| {
        return spec.s2c();
    } else {
        return &.{};
    }
}

pub fn methodsIn(self: *const Self) []const Method {
    if (self.base.spec) |spec| {
        return spec.c2s();
    } else {
        return &.{};
    }
}

pub fn errd(self: *Self) void {
    if (self.client) |client| {
        client.err = true;
    }
}

pub fn sendMessage(self: *Self, gpa: mem.Allocator, msg: anytype) void {
    if (self.client) |client| {
        client.sendMessage(gpa, msg);
    }
}

pub fn isServer(self: *const Self) bool {
    _ = self;
    return true;
}

// pub fn serverSock(self: *const Self) void {}
