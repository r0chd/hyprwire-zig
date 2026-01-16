const std = @import("std");
const types = @import("../implementation/types.zig");
const messages = @import("../message/messages/root.zig");

const mem = std.mem;

const ServerSocket = @import("../server/ServerSocket.zig");
const ClientSocket = @import("ClientSocket.zig");
const WireObject = @import("../implementation/WireObject.zig").WireObject;
const Object = @import("../implementation/Object.zig").Object;
const Method = types.Method;
const Message = messages.Message;

client: ?*ClientSocket,
spec: ?*types.ProtocolObjectSpec = null,
data: ?*anyopaque = null,
listeners: std.ArrayList(*const fn (*anyopaque) void) = .empty,
on_deinit: ?*const fn () void = null,
id: u32 = 0,
version: u32 = 0,
seq: u32 = 1,
protocol_name: []const u8 = "",

const Self = @This();

pub fn init(client: *ClientSocket) Self {
    return .{
        .client = client,
    };
}

pub fn clientSockFn(ptr: *const WireObject) ?*ClientSocket {
    const self: *const Self = @fieldParentPtr("interface", ptr);
    if (self.client) |client| {
        if (client.server) |srv| {
            return srv;
        }
    }

    return null;
}

pub fn clientSock(self: *Self) ?*ClientSocket {
    return self.client;
}

pub fn serverSock(self: *Self) ?*ServerSocket {
    _ = self;
    return null;
}

pub fn getData(self: *Self) ?*anyopaque {
    return self.data;
}

pub fn setData(self: *Self, data: ?*anyopaque) void {
    self.data = data;
}

pub fn objectDeinit(self: *Self, id: u32, message: [:0]const u8) void {
    _ = id;
    _ = message;
    if (self.on_deinit) |onDeinit| {
        onDeinit();
    }
}

pub fn setOnDeinit(self: *Self, cb: *const fn () void) void {
    self.on_deinit = cb;
}

pub fn methodsOut(self: *Self) []const Method {
    if (self.spec) |spec| {
        return spec.vtable.c2s(spec.ptr);
    } else {
        return &.{};
    }
}

pub fn methodsIn(self: *Self) []const Method {
    if (self.spec) |spec| {
        return spec.vtable.s2c(spec.ptr);
    } else {
        return &.{};
    }
}

pub fn errd(self: *Self) void {
    if (self.client) |client| {
        client.@"error" = true;
    }
}

pub fn err(self: *Self, gpa: mem.Allocator, id: u32, message: [:0]const u8) anyerror!void {
    _ = self;
    _ = gpa;
    _ = id;
    _ = message;
}

pub fn sendMessage(self: *Self, gpa: mem.Allocator, message: Message) !void {
    if (self.client) |client| {
        try client.sendMessage(gpa, message);
    }
}

pub fn getListeners(self: *Self) std.ArrayList(*const fn (*anyopaque) void) {
    return self.listeners;
}

pub fn server(self: *Self) bool {
    _ = self;
    return false;
}

pub fn deinit(self: *Self) void {
    if (self.on_deinit) |onDeinit| {
        onDeinit();
    }
}

pub fn call(self: *Self, id: u32, ...) callconv(.c) void {
    _ = self;
    _ = id;
}

pub fn listen(self: *Self, gpa: mem.Allocator, id: u32, callback: *const fn (*anyopaque) void) !void {
    if (self.listeners.items.len <= id) {
        try self.listeners.resize(gpa, id + 1);
    }
    self.listeners.appendAssumeCapacity(callback);
}

test {
    const alloc = std.testing.allocator;
    {
        const client = try ClientSocket.open(alloc, .{ .fd = 1 });
        defer client.deinit(alloc);
        var self = Self.init(client);

        const obj = Object.from(&self);
        defer obj.vtable.deinit(obj.ptr);
        try obj.vtable.err(obj.ptr, alloc, 1, "test");

        self.errd();
        var listeners = self.getListeners();
        listeners.deinit(alloc);

        const methods_in = self.methodsIn();
        _ = methods_in;

        const methods_out = self.methodsOut();
        _ = methods_out;

        var hello = messages.Hello.init();
        try self.sendMessage(alloc, Message.from(&hello));
        _ = self.server();

        // this will force the underlying fd to be invalid
        // making the ClientSocket not try to close it
        client.fd.raw = -1;
    }
}
