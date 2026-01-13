const std = @import("std");
const types = @import("types.zig");

const ServerSocket = @import("../server/ServerSocket.zig");
const ClientSocket = @import("../server/ServerClient.zig");

fn defaultClientSock() ?*ClientSocket {
    return null;
}

fn defaultServerSock() ?*ServerSocket {
    return null;
}

clientSockFn: *const fn () ?*ClientSocket = defaultClientSock,
serverSockFn: *const fn () ?*ServerSocket = defaultServerSock,
errorFn: *const fn (id: u32, message: [:0]const u8) void,

data: ?*anyopaque = null,
listeners: []*anyopaque = &.{},
id: u32 = 0,
version: u32 = 0,
seq: u32 = 1,
protocol_name: []const u8 = "",
spec: ?*types.ProtocolObjectSpec = null,

const Self = @This();

pub fn serverSock(self: *Self) ?*ServerSocket {
    return self.serverSockFn();
}

pub fn clientSock(self: *Self) ?*ClientSocket {
    return self.clientSockFn();
}

pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    if (self.listeners.len > 0) {
        gpa.free(self.listeners);
    }
    if (self.protocol_name.len > 0) {
        gpa.free(self.protocol_name);
    }
}
