const std = @import("std");
const types = @import("../implementation/types.zig");
const messages = @import("../message/messages/root.zig");
const helpers = @import("helpers");

const fmt = std.fmt;
const log = std.log.scoped(.hw);
const mem = std.mem;
const isTrace = helpers.isTrace;
const meta = std.meta;

const MessageMagic = @import("../types/MessageMagic.zig").MessageMagic;
const MessageType = @import("../message/MessageType.zig").MessageType;
const message_parser = @import("../message/MessageParser.zig");
const ServerSocket = @import("../server/ServerSocket.zig");
const ServerClient = @import("../server/ServerClient.zig");
const ClientSocket = @import("ClientSocket.zig");
const Object = @import("../implementation/Object.zig").Object;
const Method = types.Method;
const Message = messages.Message;

client: ?*ClientSocket,
spec: ?types.ProtocolObjectSpec = null,
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

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    if (isTrace()) {
        log.debug("destroying object {}", .{self.id});
    }

    self.listeners.deinit(gpa);
    if (self.on_deinit) |onDeinit| {
        onDeinit();
    }
}

pub fn call(self: *Self, gpa: mem.Allocator, id: u32, args: *types.Args) !u32 {
    const methods = self.methodsOut();
    if (methods.len <= id) {
        const msg = try fmt.allocPrintSentinel(gpa, "core protocol error: invalid method {} for object {}", .{ id, self.id }, 0);
        defer gpa.free(msg);
        log.debug("core protocol error: {s}", .{msg});
        try self.err(gpa, id, msg);
        return error.TODO;
    }

    const method = methods[id];
    const params = method.params;

    if (method.since > self.version) {
        const msg = try fmt.allocPrintSentinel(gpa, "invalid method spec {} for object {} -> server cannot call returnsType methods", .{ id, self.id }, 0);
        defer gpa.free(msg);
        log.debug("core protocol error: {s}", .{msg});
        try self.err(gpa, id, msg);
        return error.TODO;
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
        const param = meta.intToEnum(MessageMagic, params[i]) catch unreachable;
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
                const arr_type = meta.intToEnum(MessageMagic, params[i + 1]) catch return error.InvalidMessage;
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
    try self.sendMessage(gpa, Message.from(&msg));

    if (wait_on_seq != 0) {
        if (self.client) |client| {
            const obj = client.makeObject(gpa, self.protocol_name, method.returns_type, wait_on_seq);
            if (obj) |o| {
                try client.waitForObject(gpa, o);
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
