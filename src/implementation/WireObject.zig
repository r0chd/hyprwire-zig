const std = @import("std");
const types = @import("types.zig");

const ServerSocket = @import("../server/ServerSocket.zig");
const ClientSocket = @import("../server/ServerClient.zig");

data: ?*anyopaque = null,
on_destroy: ?*const fn () void = null,

listeners: []*anyopaque = &.{},
id: u32 = 0,
version: u32 = 0,
seq: u32 = 1,
protocol_name: []const u8 = "",
spec: ?*types.ProtocolObjectSpec = null,
self: ?*Self = null,

const Self = @This();

pub fn serverSock(self: *Self) ?*ServerSocket {
    _ = self;
    return null;
}

pub fn clientSock(self: *Self) ?*ClientSocket {
    _ = self;
    return null;
}

pub fn setData(self: *Self, data_ptr: ?*anyopaque) void {
    self.data = data_ptr;
}

pub fn getData(self: *Self) ?*anyopaque {
    return self.data;
}

pub fn setOnDestroy(self: *Self, callback: ?*const fn () void) void {
    self.on_destroy = callback;
}

pub fn err(self: *Self, message: [:0]const u8) void {
    _ = self;
    _ = message;
}

pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    if (self.on_destroy) |cb| {
        cb();
    }
    if (self.listeners.len > 0) {
        gpa.free(self.listeners);
    }
    if (self.protocol_name.len > 0) {
        gpa.free(self.protocol_name);
    }
}
