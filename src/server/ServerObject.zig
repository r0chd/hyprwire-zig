const std = @import("std");
const fmt = std.fmt;
const enums = std.enums;
const mem = std.mem;
const meta = std.meta;

const helpers = @import("helpers");
const isTrace = helpers.isTrace;

const Io = std.Io;
const ClientSocket = @import("../client/ClientSocket.zig");
const Object = @import("../implementation/Object.zig").Object;
const types = @import("../implementation/types.zig");
const Method = types.Method;
const WireObject = @import("../implementation/WireObject.zig").WireObject;
const message_parser = @import("../message/MessageParser.zig");
const FatalErrorMessage = @import("../message/messages/FatalProtocolError.zig");
const messages = @import("../message/messages/root.zig");
const Message = messages.Message;
const MessageType = @import("../message/MessageType.zig").MessageType;
const MessageMagic = @import("../types/MessageMagic.zig").MessageMagic;
const ServerClient = @import("ServerClient.zig");
const ServerSocket = @import("ServerSocket.zig");

const log = std.log.scoped(.hw);
pub const MAX_ERROR_MSG_SIZE: usize = 256;

client: ?*ServerClient,
spec: ?types.ProtocolObjectSpec = null,
data: ?*anyopaque = null,
listeners: std.ArrayList(*anyopaque) = .empty,
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

pub fn sendMessage(self: *Self, gpa: mem.Allocator, io: Io, message: Message) !void {
    if (self.client) |client| {
        client.sendMessage(gpa, io, message);
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

pub fn @"error"(self: *Self, gpa: mem.Allocator, io: Io, id: u32, message: [:0]const u8) void {
    // TODO:
    // Figure out memory management that won't error
    var buffer: [1024]u8 = undefined;
    var msg = FatalErrorMessage.initBuffer(&buffer, self.id, id, message);
    if (self.client) |client| {
        client.sendMessage(gpa, io, Message.from(&msg));
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

pub fn call(self: *Self, gpa: mem.Allocator, io: Io, id: u32, args: *types.Args) !u32 {
    const methods = self.methodsOut();
    if (methods.len <= id) {
        const msg = try fmt.allocPrintSentinel(gpa, "core protocol error: invalid method {} for object {}", .{ id, self.id }, 0);
        defer gpa.free(msg);
        log.debug("core protocol error: {s}", .{msg});
        self.@"error"(gpa, io, id, msg);
        return error.InvalidMethod;
    }

    const method = methods[id];
    const params = method.params;

    if (method.since > self.version) {
        const msg = try fmt.allocPrintSentinel(gpa, "invalid method spec {} for object {} -> server cannot call returnsType methods", .{ id, self.id }, 0);
        defer gpa.free(msg);
        log.debug("core protocol error: {s}", .{msg});
        self.@"error"(gpa, io, id, msg);
        return error.InvalidMethod;
    }

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    var fds: std.ArrayList(i32) = .empty;
    defer fds.deinit(gpa);

    try data.append(gpa, @intFromEnum(MessageType.generic_protocol_message));
    try data.append(gpa, @intFromEnum(MessageMagic.type_object));

    var object_id_buf: [4]u8 = undefined;
    mem.writeInt(u32, &object_id_buf, self.id, .little);
    try data.appendSlice(gpa, &object_id_buf);

    try data.append(gpa, @intFromEnum(MessageMagic.type_uint));
    var method_id_buf: [4]u8 = undefined;
    mem.writeInt(u32, &method_id_buf, id, .little);
    try data.appendSlice(gpa, &method_id_buf);

    var i: usize = 0;
    while (i < params.len) : (i += 1) {
        const param = enums.fromInt(MessageMagic, params[i]) orelse return error.InvalidMessage;
        switch (param) {
            .type_uint => {
                try data.append(gpa, @intFromEnum(MessageMagic.type_uint));
                const arg = (args.next() orelse return error.InvalidMessage).get(u32) orelse return error.InvalidMessage;
                var buf: [4]u8 = undefined;
                mem.writeInt(u32, &buf, arg, .little);
                try data.appendSlice(gpa, &buf);
            },
            .type_int => {
                try data.append(gpa, @intFromEnum(MessageMagic.type_int));
                const arg = (args.next() orelse return error.InvalidMessage).get(i32) orelse return error.InvalidMessage;
                var buf: [4]u8 = undefined;
                mem.writeInt(i32, &buf, arg, .little);
                try data.appendSlice(gpa, &buf);
            },
            .type_object => {
                try data.append(gpa, @intFromEnum(MessageMagic.type_object));
                const arg = (args.next() orelse return error.InvalidMessage).get(u32) orelse return error.InvalidMessage;
                var buf: [4]u8 = undefined;
                mem.writeInt(u32, &buf, arg, .little);
                try data.appendSlice(gpa, &buf);
            },
            .type_f32 => {
                try data.append(gpa, @intFromEnum(MessageMagic.type_f32));
                const arg = (args.next() orelse return error.InvalidMessage).get(f32) orelse return error.InvalidMessage;
                const bits: u32 = @bitCast(arg);
                var buf: [4]u8 = undefined;
                mem.writeInt(u32, &buf, bits, .little);
                try data.appendSlice(gpa, &buf);
            },
            .type_varchar => {
                try data.append(gpa, @intFromEnum(MessageMagic.type_varchar));
                const str = (args.next() orelse return error.InvalidMessage).get([:0]const u8) orelse return error.InvalidMessage;
                var len_buf: [10]u8 = undefined;
                try data.appendSlice(gpa, message_parser.encodeVarInt(str.len, &len_buf));
                try data.appendSlice(gpa, str[0..str.len]);
            },
            .type_array => {
                if (i + 1 >= params.len) return error.InvalidMessage;
                const arr_type = enums.fromInt(MessageMagic, params[i + 1]) orelse return error.InvalidMessage;
                i += 1;

                try data.append(gpa, @intFromEnum(MessageMagic.type_array));
                try data.append(gpa, @intFromEnum(arr_type));

                switch (arr_type) {
                    .type_uint => {
                        const arr = (args.next() orelse return error.InvalidMessage).get([]const u32) orelse return error.InvalidMessage;
                        var len_buf: [10]u8 = undefined;
                        try data.appendSlice(gpa, message_parser.encodeVarInt(arr.len, &len_buf));
                        for (arr) |v| {
                            var buf: [4]u8 = undefined;
                            mem.writeInt(u32, &buf, v, .little);
                            try data.appendSlice(gpa, &buf);
                        }
                    },
                    .type_int => {
                        const arr = (args.next() orelse return error.InvalidMessage).get([]const i32) orelse return error.InvalidMessage;
                        var len_buf: [10]u8 = undefined;
                        try data.appendSlice(gpa, message_parser.encodeVarInt(arr.len, &len_buf));
                        for (arr) |v| {
                            var buf: [4]u8 = undefined;
                            mem.writeInt(i32, &buf, v, .little);
                            try data.appendSlice(gpa, &buf);
                        }
                    },
                    .type_f32 => {
                        const arr = (args.next() orelse return error.InvalidMessage).get([]const f32) orelse return error.InvalidMessage;
                        var len_buf: [10]u8 = undefined;
                        try data.appendSlice(gpa, message_parser.encodeVarInt(arr.len, &len_buf));
                        for (arr) |v| {
                            const bits: u32 = @bitCast(v);
                            var buf: [4]u8 = undefined;
                            mem.writeInt(u32, &buf, bits, .little);
                            try data.appendSlice(gpa, &buf);
                        }
                    },
                    .type_varchar => {
                        const arr = (args.next() orelse return error.InvalidMessage).get([]const [:0]const u8) orelse return error.InvalidMessage;
                        var len_buf: [10]u8 = undefined;
                        try data.appendSlice(gpa, message_parser.encodeVarInt(arr.len, &len_buf));
                        for (arr) |s| {
                            var slen_buf: [10]u8 = undefined;
                            try data.appendSlice(gpa, message_parser.encodeVarInt(s.len, &slen_buf));
                            try data.appendSlice(gpa, s[0..s.len]);
                        }
                    },
                    .type_fd => {
                        const fd = (args.next() orelse return error.InvalidMessage).get(i32) orelse return error.InvalidMessage;
                        try fds.append(gpa, fd);
                        var len_buf: [10]u8 = undefined;
                        try data.appendSlice(gpa, message_parser.encodeVarInt(1, &len_buf));
                    },
                    else => return error.InvalidMessage,
                }
            },
            .type_fd => {
                try data.append(gpa, @intFromEnum(MessageMagic.type_fd));
                const fd = (args.next() orelse return error.InvalidMessage).get(i32) orelse return error.InvalidMessage;
                try fds.append(gpa, fd);
            },
            else => {},
        }
    }

    try data.append(gpa, @intFromEnum(MessageMagic.end));

    var msg = try messages.GenericProtocolMessage.init(gpa, data.items, fds.items);
    defer msg.deinit(gpa);
    try self.sendMessage(gpa, io, Message.from(&msg));

    return 0;
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
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    {
        var client = try ServerClient.init(1);
        var self = Self.init(&client);

        self.@"error"(alloc, io, 1, "test");
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
        try self.sendMessage(alloc, io, Message.from(&hello));
        _ = self.server();
    }
}
