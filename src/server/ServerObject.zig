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
        .call = callWrapper,
        .listen = listenWrapper,
        .clientSock = clientSockWrapper,
        .serverSock = serverSockWrapper,
        .setData = setDataWrapper,
        .getData = getDataWrapper,
        .@"error" = errorWrapper,
        .deinit = deinitWrapper,
        .setOnDeinit = setOnDeinitWrapper,
        .getClient = getClientWrapper,
    },
    .getVersion = getVersionWrapper,
    .getListeners = getListenersWrapper,
    .methodsOut = methodsOutWrapper,
    .methodsIn = methodsInWrapper,
    .errd = errdWrapper,
    .sendMessage = sendMessageWrapper,
    .server = serverWrapper,
    .getId = getIdWrapper,
};

pub fn asWireObject(self: *Self) WireObject {
    return .{ .ptr = self, .vtable = &vtable };
}

pub fn asObject(self: *Self) Object {
    return .{ .ptr = self, .vtable = &vtable.object };
}

// VTable wrappers
fn callWrapper(ptr: *anyopaque, io: std.Io, gpa: mem.Allocator, id: u32, args: *types.Args) anyerror!u32 {
    const self: *Self = @ptrCast(@alignCast(ptr));
    return self.call(io, gpa, id, args);
}

fn listenWrapper(ptr: *anyopaque, gpa: mem.Allocator, id: u32, callback: *const fn (*anyopaque) void) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    return self.listen(gpa, id, callback);
}

fn clientSockWrapper(ptr: *anyopaque) ?*ClientSocket {
    const self: *Self = @ptrCast(@alignCast(ptr));
    return self.clientSock();
}

fn serverSockWrapper(ptr: *anyopaque) ?*ServerSocket {
    const self: *Self = @ptrCast(@alignCast(ptr));
    return self.serverSock();
}

fn setDataWrapper(ptr: *anyopaque, data: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.setData(data);
}

fn getDataWrapper(ptr: *anyopaque) ?*anyopaque {
    const self: *Self = @ptrCast(@alignCast(ptr));
    return self.getData();
}

fn errorWrapper(ptr: *anyopaque, io: std.Io, gpa: mem.Allocator, id: u32, message: [:0]const u8) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.@"error"(io, gpa, id, message);
}

fn deinitWrapper(ptr: *anyopaque, gpa: mem.Allocator) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.deinit(gpa);
}

fn setOnDeinitWrapper(ptr: *anyopaque, cb: *const fn () void) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.setOnDeinit(cb);
}

fn getClientWrapper(ptr: *anyopaque) ?*ServerClient {
    const self: *Self = @ptrCast(@alignCast(ptr));
    return self.getClient();
}

fn getVersionWrapper(ptr: *anyopaque) u32 {
    const self: *Self = @ptrCast(@alignCast(ptr));
    return self.getVersion();
}

fn getListenersWrapper(ptr: *anyopaque) []*anyopaque {
    const self: *Self = @ptrCast(@alignCast(ptr));
    return self.getListeners();
}

fn methodsOutWrapper(ptr: *anyopaque) []const Method {
    const self: *Self = @ptrCast(@alignCast(ptr));
    return self.methodsOut();
}

fn methodsInWrapper(ptr: *anyopaque) []const Method {
    const self: *Self = @ptrCast(@alignCast(ptr));
    return self.methodsIn();
}

fn errdWrapper(ptr: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.errd();
}

fn sendMessageWrapper(ptr: *anyopaque, io: std.Io, gpa: mem.Allocator, message: *Message) anyerror!void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    return self.sendMessage(io, gpa, message);
}

fn serverWrapper(ptr: *anyopaque) bool {
    const self: *Self = @ptrCast(@alignCast(ptr));
    return self.server();
}

fn getIdWrapper(ptr: *anyopaque) u32 {
    const self: *Self = @ptrCast(@alignCast(ptr));
    return self.getId();
}

pub fn init(client: *ServerClient) Self {
    return .{
        .client = client,
    };
}

pub fn methodsOut(self: *Self) []const Method {
    if (self.spec) |spec| {
        return spec.s2c();
    } else {
        return &.{};
    }
}

pub fn methodsIn(self: *Self) []const Method {
    if (self.spec) |spec| {
        return spec.c2s();
    } else {
        return &.{};
    }
}

pub fn errd(self: *Self) void {
    if (self.client) |client| {
        client.@"error" = true;
    }
}

pub fn sendMessage(self: *Self, io: Io, gpa: mem.Allocator, message: *Message) !void {
    if (self.client) |client| {
        client.sendMessage(io, gpa, message);
    }
}

pub fn server(self: *Self) bool {
    _ = self;
    return true;
}

pub fn clientSock(self: *Self) ?*ClientSocket {
    _ = self;
    return null;
}

pub fn serverSock(self: *Self) ?*ServerSocket {
    if (self.client) |client| {
        if (client.server) |srv| {
            return srv;
        }
    }
    return null;
}

pub fn getClient(self: *Self) ?*ServerClient {
    return self.client;
}

pub fn getData(self: *Self) ?*anyopaque {
    return self.data;
}

pub fn setData(self: *Self, data: *anyopaque) void {
    self.data = data;
}

pub fn setOnDeinit(self: *Self, cb: *const fn () void) void {
    self.on_deinit = cb;
}

pub fn @"error"(self: *Self, io: Io, gpa: mem.Allocator, id: u32, message: [:0]const u8) void {
    // TODO:
    // Figure out memory management that won't error
    var buffer: [1024]u8 = undefined;
    var msg = FatalErrorMessage.initBuffer(&buffer, self.id, id, message);
    if (self.client) |client| {
        client.sendMessage(io, gpa, &msg.interface);
    }

    self.errd();
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
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

pub fn call(self: *Self, io: Io, gpa: mem.Allocator, id: u32, args: *types.Args) !u32 {
    return self.asWireObject().callMethod(io, gpa, id, args);
}

pub fn listen(self: *Self, gpa: mem.Allocator, id: u32, callback: *const fn (*anyopaque) void) !void {
    if (self.listeners.items.len <= id) {
        try self.listeners.resize(gpa, id + 1);
    }
    self.listeners.items[id] = @constCast(callback);
}

pub fn getId(self: *Self) u32 {
    return self.id;
}

pub fn getListeners(self: *Self) []*anyopaque {
    return self.listeners.items;
}

pub fn getVersion(self: *Self) u32 {
    return self.version;
}

test {
    std.testing.refAllDecls(@This());
}
