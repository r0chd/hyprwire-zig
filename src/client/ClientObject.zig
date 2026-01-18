const std = @import("std");
const types = @import("../implementation/types.zig");
const messages = @import("../message/messages/root.zig");
const helpers = @import("helpers");

const fmt = std.fmt;
const log = std.log;
const mem = std.mem;
const isTrace = helpers.isTrace;
const meta = std.meta;

const MessageMagic = @import("../types/MessageMagic.zig").MessageMagic;
const MessageType = @import("../message/MessageType.zig").MessageType;
const ServerSocket = @import("../server/ServerSocket.zig");
const ClientSocket = @import("ClientSocket.zig");
const WireObject = @import("../implementation/WireObject.zig").WireObject;
const Object = @import("../implementation/Object.zig").Object;
const Method = types.Method;
const Message = messages.Message;

client: ?*ClientSocket,
spec: ?types.ProtocolObjectSpec = null,
data: ?*anyopaque = null,
listeners: std.ArrayList(?*anyopaque) = .empty,
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

pub fn server(self: *Self) bool {
    _ = self;
    return false;
}

pub fn deinit(self: *Self) void {
    if (isTrace()) {
        log.debug("destroying object {}", .{self.id});
    }

    if (self.on_deinit) |onDeinit| {
        onDeinit();
    }
}

pub fn call(self: *Self, gpa: mem.Allocator, id: u32) !u32 {
    _ = self;
    // const methods = self.methodsOut();
    _ = gpa;
    _ = id;
    // if (methods.len <= id) {
    //     const msg = try fmt.allocPrintSentinel(gpa, "core protocol error: invalid method {} for object {}", .{ id, self.id }, 0);
    //     defer gpa.free(msg);
    //     log.debug("core protocol error: {s}", .{msg});
    //     try self.err(gpa, id, msg);
    //     return error.TODO;
    // }

    // const method = methods[id];
    // const params = method.params;

    // if (method.since > self.version) {
    //     const msg = try fmt.allocPrintSentinel(gpa, "invalid method spec {} for object {} -> server cannot call returnsType methods", .{ id, self.id }, 0);
    //     defer gpa.free(msg);
    //     log.debug("core protocol error: {s}", .{msg});
    //     try self.err(gpa, id, msg);
    //     return error.TODO;
    // }

    // var data: std.ArrayList(u8) = .empty;
    // // var fds: std.ArrayList(i32) = .empty;

    // try data.append(gpa, @intFromEnum(MessageType.generic_protocol_message));
    // try data.append(gpa, @intFromEnum(MessageMagic.type_object));

    // try data.appendSlice(gpa, &mem.toBytes(id));

    // var wait_on_seq: usize = 0;

    // if (method.returns_type.len > 0) {
    //     try data.append(gpa, @intFromEnum(MessageMagic.type_seq));

    //     const self_client = self;
    //     if (self_client.client) |client| {
    //         client.seq += 1;
    //         wait_on_seq = client.seq;
    //     }

    //     try data.appendSlice(gpa, &mem.toBytes(wait_on_seq));
    // }

    // for (0..params.len) |i| {
    //     const param = meta.intToEnum(MessageMagic, params[i]) catch unreachable;
    //     switch (param) {
    //         .type_uint => {
    //             try data.append(gpa, @intFromEnum(MessageMagic.type_uint));
    //             try data.resize(gpa, data.items.len + 4);
    //         },
    //         .type_int => {},
    //         .type_object => {},
    //         .type_f32 => {},
    //         .type_varchar => {},
    //         .type_array => {},
    //         .type_fd => {},
    //         else => {},
    //     }
    // }

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
        const client = try ClientSocket.open(alloc, .{ .fd = 1 });
        defer client.deinit(alloc);
        var self = Self.init(client);

        const obj = Object.from(&self);
        defer obj.vtable.deinit(obj.ptr);
        try obj.vtable.err(obj.ptr, alloc, 1, "test");

        self.errd();

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
