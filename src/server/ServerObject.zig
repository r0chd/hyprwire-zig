const std = @import("std");
const types = @import("../implementation/types.zig");
const messages = @import("../message/messages/root.zig");
const helpers = @import("helpers");

const log = std.log;
const mem = std.mem;
const isTrace = helpers.isTrace;

const FatalErrorMessage = @import("../message/messages/FatalProtocolError.zig");
const ServerSocket = @import("ServerSocket.zig");
const ClientSocket = @import("../client/ClientSocket.zig");
const ServerClient = @import("ServerClient.zig");
const WireObject = @import("../implementation/WireObject.zig").WireObject;
const Object = @import("../implementation/Object.zig").Object;
const Message = messages.Message;
const Method = types.Method;

client: ?*ServerClient,
spec: ?types.ProtocolObjectSpec = null,
data: ?*anyopaque = null,
listeners: std.ArrayList(?*anyopaque) = .empty,
on_deinit: ?*const fn () void = null,
id: u32 = 0,
version: u32 = 0,
seq: u32 = 1,
protocol_name: []const u8 = "",

const Self = @This();

pub fn init(client: *ServerClient) Self {
    return .{
        .client = client,
    };
}

pub fn methodsOut(self: *Self) []const Method {
    if (self.spec) |spec| {
        return spec.vtable.s2c(spec.ptr);
    } else {
        return &.{};
    }
}

pub fn methodsIn(self: *Self) []const Method {
    if (self.spec) |spec| {
        return spec.vtable.c2s(spec.ptr);
    } else {
        return &.{};
    }
}

pub fn errd(self: *Self) void {
    if (self.client) |client| {
        client.@"error" = true;
    }
}

pub fn sendMessage(self: *Self, gpa: mem.Allocator, message: Message) !void {
    if (self.client) |client| {
        client.sendMessage(gpa, message);
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

pub fn getData(self: *Self) ?*anyopaque {
    return self.data;
}

pub fn setData(self: *Self, data: ?*anyopaque) void {
    self.data = data;
}

pub fn setOnDeinit(self: *Self, cb: *const fn () void) void {
    self.on_deinit = cb;
}

pub fn err(self: *Self, gpa: mem.Allocator, id: u32, message: [:0]const u8) !void {
    var msg = try FatalErrorMessage.init(gpa, self.id, id, message);
    defer msg.deinit(gpa);
    if (self.client) |client| {
        client.sendMessage(gpa, Message.from(&msg));
    }

    self.errd();
}

pub fn deinit(self: *Self) void {
    if (isTrace()) {
        const fd = if (self.client) |client| client.fd.raw else -1;
        log.debug("[{}] destroying object {}", .{ fd, self.id });
    }
    if (self.on_deinit) |onDeinit| {
        onDeinit();
    }
}

pub fn call(self: *Self, gpa: mem.Allocator, id: u32) !u32 {
    _ = gpa;
    _ = self;
    _ = id;

    return 0;
}

pub fn listen(self: *Self, gpa: mem.Allocator, id: u32, callback: *const fn (*anyopaque) void) !void {
    if (self.listeners.items.len <= id) {
        try self.listeners.resize(gpa, id + 1);
    }
    self.listeners.appendAssumeCapacity(@constCast(callback));
}

pub fn getId(self: *Self) u32 {
    return self.id;
}

pub fn getListeners(self: *Self) []?*anyopaque {
    return self.listeners.items;
}

pub fn getVersion(self: *Self) u32 {
    return self.version;
}

test {
    const alloc = std.testing.allocator;
    {
        var client = try ServerClient.init(1);
        var self = Self.init(&client);

        try self.err(alloc, 1, "test");
        const obj = Object.from(&self);
        _ = obj;

        const wire_object = WireObject.from(&self);
        _ = wire_object;

        self.errd();

        const methods_in = self.methodsIn();
        _ = methods_in;

        const methods_out = self.methodsOut();
        _ = methods_out;

        var hello = messages.Hello.init();
        try self.sendMessage(alloc, Message.from(&hello));
        _ = self.server();
    }
}
