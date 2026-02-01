const std = @import("std");
const enums = std.enums;
const fmt = std.fmt;
const mem = std.mem;
const Io = std.Io;

const helpers = @import("helpers");
const isTrace = helpers.isTrace;

const Object = @import("../implementation/Object.zig");
const types = @import("../implementation/types.zig");
const Method = types.Method;
const WireObject = types.WireObject;
const MessageMagic = types.MessageMagic;
const message_parser = @import("../message/MessageParser.zig");
const Message = @import("../message/messages/Message.zig");
const MessageType = @import("../message/MessageType.zig").MessageType;
const ServerClient = @import("../server/ServerClient.zig");
const ServerSocket = @import("../server/ServerSocket.zig");
const ClientSocket = @import("ClientSocket.zig");

const log = std.log.scoped(.hw);

client: ?*ClientSocket,
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
        .clientSock = clientSock,
        .setData = setData,
        .getData = getData,
        .@"error" = @"error",
        .deinit = deinit,
        .setOnDeinit = setOnDeinit,
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

pub fn init(client: *ClientSocket) Self {
    return .{
        .client = client,
    };
}

fn clientSock(ptr: *anyopaque) ?*ClientSocket {
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

fn methodsOut(ptr: *anyopaque) []const Method {
    const self: *Self = @ptrCast(@alignCast(ptr));
    if (self.spec) |spec| {
        return spec.c2s();
    } else {
        return &.{};
    }
}

fn methodsIn(ptr: *anyopaque) []const Method {
    const self: *Self = @ptrCast(@alignCast(ptr));
    if (self.spec) |spec| {
        return spec.s2c();
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

fn @"error"(ptr: *anyopaque, io: Io, gpa: mem.Allocator, id: u32, message: [:0]const u8) void {
    _ = ptr;
    _ = io;
    _ = gpa;
    _ = id;
    _ = message;
}

fn sendMessage(ptr: *anyopaque, io: Io, gpa: mem.Allocator, message: *Message) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    if (self.client) |client| {
        try client.sendMessage(io, gpa, message);
    }
}

fn server(ptr: *anyopaque) bool {
    _ = ptr;
    return false;
}

pub fn deinit(ptr: *anyopaque, gpa: mem.Allocator) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    if (isTrace()) {
        log.debug("destroying object {}", .{self.id});
    }

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
        try self.listeners.ensureTotalCapacity(gpa, id + 1);
    }
    self.listeners.appendAssumeCapacity(@constCast(callback));
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
