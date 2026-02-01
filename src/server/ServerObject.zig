const std = @import("std");
const fmt = std.fmt;
const enums = std.enums;
const mem = std.mem;
const Io = std.Io;

const helpers = @import("helpers");
const isTrace = helpers.isTrace;

const ClientSocket = @import("../client/ClientSocket.zig");
const Object = @import("../implementation/Object.zig");
const types = @import("../implementation/types.zig");
const Method = types.Method;
const WireObject = @import("../implementation/WireObject.zig");
const message_parser = @import("../message/MessageParser.zig");
const FatalErrorMessage = @import("../message/messages/FatalProtocolError.zig");
const Message = @import("../message/messages/Message.zig");
const MessageType = @import("../message/MessageType.zig").MessageType;
const MessageMagic = @import("../types/MessageMagic.zig").MessageMagic;
const ServerClient = @import("ServerClient.zig");
const ServerSocket = @import("ServerSocket.zig");

const log = std.log.scoped(.hw);

pub const MAX_ERROR_MSG_SIZE: usize = 256;

client: ?*ServerClient,
spec: ?*const types.ProtocolObjectSpec = null,
data: ?*anyopaque = null,
listeners: std.ArrayList(*anyopaque) = .empty,
on_deinit: ?*const fn () void = null,
id: u32 = 0,
version: u32 = 0,
seq: u32 = 1,
protocol_name: []const u8 = "",

const Self = @This();

pub const vtable: WireObject.VTable = .{
    .object = .{
        .call = call,
        .listen = listen,
        .serverSock = serverSock,
        .setData = setData,
        .getData = getData,
        .@"error" = @"error",
        .deinit = deinit,
        .setOnDeinit = setOnDeinit,
        .getClient = getClient,
    },
    .getVersion = getVersion,
    .getListeners = getListeners,
    .methodsOut = methodsOut,
    .methodsIn = methodsIn,
    .errd = errd,
    .sendMessage = sendMessage,
    .server = server,
    .getId = getId,
};

pub fn asWireObject(self: *Self) WireObject {
    return .{ .ptr = self, .vtable = &vtable };
}

pub fn asObject(self: *Self) Object {
    return .{ .ptr = self, .vtable = &vtable.object };
}

pub fn init(client: *ServerClient) Self {
    return .{
        .client = client,
    };
}

fn methodsOut(ptr: *anyopaque) []const Method {
    const self: *Self = @ptrCast(@alignCast(ptr));
    if (self.spec) |spec| {
        return spec.s2c();
    } else {
        return &.{};
    }
}

fn methodsIn(ptr: *anyopaque) []const Method {
    const self: *Self = @ptrCast(@alignCast(ptr));
    if (self.spec) |spec| {
        return spec.c2s();
    } else {
        return &.{};
    }
}

fn errd(ptr: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    if (self.client) |client| {
        client.@"error" = true;
    }
}

fn sendMessage(ptr: *anyopaque, io: Io, gpa: mem.Allocator, message: *Message) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    if (self.client) |client| {
        client.sendMessage(io, gpa, message);
    }
}

fn server(ptr: *anyopaque) bool {
    _ = ptr;
    return true;
}

fn serverSock(ptr: *anyopaque) ?*ServerSocket {
    const self: *Self = @ptrCast(@alignCast(ptr));
    if (self.client) |client| {
        if (client.server) |srv| {
            return srv;
        }
    }
    return null;
}

fn getClient(ptr: *anyopaque) ?*ServerClient {
    const self: *Self = @ptrCast(@alignCast(ptr));
    return self.client;
}

fn getData(ptr: *anyopaque) ?*anyopaque {
    const self: *Self = @ptrCast(@alignCast(ptr));
    return self.data;
}

fn setData(ptr: *anyopaque, data: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.data = data;
}

fn setOnDeinit(ptr: *anyopaque, cb: *const fn () void) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.on_deinit = cb;
}

fn @"error"(ptr: *anyopaque, io: Io, gpa: mem.Allocator, id: u32, message: [:0]const u8) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    // TODO:
    // Figure out memory management that won't error
    var buffer: [1024]u8 = undefined;
    var msg = FatalErrorMessage.initBuffer(&buffer, self.id, id, message);
    if (self.client) |client| {
        client.sendMessage(io, gpa, &msg.interface);
    }

    errd(ptr);
}

fn deinit(ptr: *anyopaque, gpa: mem.Allocator) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    if (isTrace()) {
        const fd = if (self.client) |client| client.stream.socket.handle else -1;
        log.debug("[{}] destroying object {}", .{ fd, self.id });
    }

    gpa.free(self.protocol_name);
    self.listeners.deinit(gpa);
    if (self.on_deinit) |onDeinit| {
        onDeinit();
    }
}

fn call(ptr: *anyopaque, io: Io, gpa: mem.Allocator, id: u32, args: *types.Args) anyerror!u32 {
    const self: *Self = @ptrCast(@alignCast(ptr));
    return WireObject.from(self).callMethod(io, gpa, id, args);
}

fn listen(ptr: *anyopaque, gpa: mem.Allocator, id: u32, callback: *const fn (*anyopaque) void) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    if (self.listeners.items.len <= id) {
        try self.listeners.resize(gpa, id + 1);
    }
    self.listeners.items[id] = @constCast(callback);
}

fn getId(ptr: *anyopaque) u32 {
    const self: *Self = @ptrCast(@alignCast(ptr));
    return self.id;
}

fn getListeners(ptr: *anyopaque) []*anyopaque {
    const self: *Self = @ptrCast(@alignCast(ptr));
    return self.listeners.items;
}

fn getVersion(ptr: *anyopaque) u32 {
    const self: *Self = @ptrCast(@alignCast(ptr));
    return self.version;
}

test {
    std.testing.refAllDecls(@This());
}
