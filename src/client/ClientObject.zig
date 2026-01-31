const std = @import("std");
const enums = std.enums;
const fmt = std.fmt;
const mem = std.mem;
const Io = std.Io;

const helpers = @import("helpers");
const isTrace = helpers.isTrace;

const types = @import("../implementation/types.zig");
const Method = types.Method;
const message_parser = @import("../message/MessageParser.zig");
const Message = @import("../message/messages/Message.zig");
const MessageType = @import("../message/MessageType.zig").MessageType;
const ServerClient = @import("../server/ServerClient.zig");
const ServerSocket = @import("../server/ServerSocket.zig");
const MessageMagic = @import("../types/MessageMagic.zig").MessageMagic;
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

pub fn getClient(self: *Self) ?*ServerClient {
    _ = self;
    return null;
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

pub fn methodsOut(self: *Self) []const Method {
    if (self.spec) |spec| {
        return spec.c2s();
    } else {
        return &.{};
    }
}

pub fn methodsIn(self: *Self) []const Method {
    if (self.spec) |spec| {
        return spec.s2c();
    } else {
        return &.{};
    }
}

pub fn errd(self: *Self) void {
    if (self.client) |client| {
        client.@"error" = true;
    }
}

pub fn @"error"(self: *Self, io: Io, gpa: mem.Allocator, id: u32, message: [:0]const u8) void {
    _ = self;
    _ = io;
    _ = gpa;
    _ = id;
    _ = message;
}

pub fn sendMessage(self: *Self, io: Io, gpa: mem.Allocator, message: *Message) !void {
    if (self.client) |client| {
        try client.sendMessage(io, gpa, message);
    }
}

pub fn server(self: *Self) bool {
    _ = self;
    return false;
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    if (isTrace()) {
        log.debug("destroying object {}", .{self.id});
    }

    self.listeners.deinit(gpa);
    if (self.on_deinit) |onDeinit| {
        onDeinit();
    }
}

pub fn call(self: *Self, io: Io, gpa: mem.Allocator, id: u32, args: *types.Args) !u32 {
    const methods = self.methodsOut();
    if (methods.len <= id) {
        const msg = try fmt.allocPrintSentinel(gpa, "core protocol error: invalid method {} for object {}", .{ id, self.id }, 0);
        defer gpa.free(msg);
        log.debug("core protocol error: {s}", .{msg});
        self.@"error"(io, gpa, id, msg);
        return error.InvalidMethod;
    }

    const method = methods[id];
    const params = method.params;

    if (method.since > self.version) {
        const msg = try fmt.allocPrintSentinel(gpa, "invalid method spec {} for object {} -> server cannot call returnsType methods", .{ id, self.id }, 0);
        defer gpa.free(msg);
        log.debug("core protocol error: {s}", .{msg});
        self.@"error"(io, gpa, id, msg);
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

    var wait_on_seq: u32 = 0;

    if (method.returns_type.len > 0) {
        try data.append(gpa, @intFromEnum(MessageMagic.type_seq));

        const self_client = self;
        if (self_client.client) |client| {
            client.seq += 1;
            wait_on_seq = client.seq;
        }

        var seq_buf: [4]u8 = undefined;
        mem.writeInt(u32, &seq_buf, wait_on_seq, .little);
        try data.appendSlice(gpa, &seq_buf);
    }

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
                        const fd_list = (args.next() orelse return error.InvalidMessage).get([]const i32) orelse return error.InvalidMessage;
                        for (fd_list) |fd| {
                            try fds.append(gpa, fd);
                        }
                        var len_buf: [10]u8 = undefined;
                        try data.appendSlice(gpa, message_parser.encodeVarInt(fd_list.len, &len_buf));
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

    var msg = try Message.GenericProtocolMessage.init(gpa, data.items, fds.items);
    defer msg.deinit(gpa);
    try self.sendMessage(io, gpa, &msg.interface);

    if (wait_on_seq != 0) {
        if (self.client) |client| {
            const obj = client.makeObject(gpa, self.protocol_name, method.returns_type, wait_on_seq);
            if (obj) |o| {
                try client.waitForObject(io, gpa, o);
                return o.id;
            }
        }
    }

    return 0;
}

pub fn listen(self: *Self, gpa: mem.Allocator, id: u32, callback: *const fn (*anyopaque) void) !void {
    if (self.listeners.items.len <= id) {
        try self.listeners.ensureTotalCapacity(gpa, id + 1);
    }
    self.listeners.appendAssumeCapacity(@constCast(callback));
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
