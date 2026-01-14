const std = @import("std");

const mem = std.mem;

const MessageType = @import("../MessageType.zig").MessageType;
const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;
const Message = @import("root.zig");

pub const vtable: Message.VTable = .{
    .getFds = getFds,
    .getData = getData,
    .getLen = getLen,
    .getMessageType = getMessageType,
};

pub fn getFds(ptr: *anyopaque) []const i32 {
    _ = ptr;

    return &.{};
}

pub fn getData(ptr: *anyopaque) []const u8 {
    const self: *const Self = @ptrCast(@alignCast(ptr));

    return self.data;
}

pub fn getLen(ptr: *anyopaque) usize {
    const self: *const Self = @ptrCast(@alignCast(ptr));

    return self.len;
}

pub fn getMessageType(ptr: *anyopaque) MessageType {
    const self: *const Self = @ptrCast(@alignCast(ptr));

    return self.message_type;
}

data: []const u8,
len: usize,
message_type: MessageType = .invalid,

const Self = @This();

pub fn init() Self {
    const data = &.{
        @intFromEnum(MessageType.sup),
        @intFromEnum(MessageMagic.type_varchar),
        0x03,
        'V',
        'A',
        'X',
        @intFromEnum(MessageMagic.end),
    };

    return .{
        .data = data,
        .len = data.len,
        .message_type = .sup,
    };
}

pub fn fromBytes(data: []const u8, offset: usize) !Self {
    if (offset + 7 > data.len) return error.OutOfRange;

    const expected = [_]u8{
        @intFromEnum(MessageType.sup),
        @intFromEnum(MessageMagic.type_varchar),
        0x03,
        'V',
        'A',
        'X',
        @intFromEnum(MessageMagic.end),
    };

    if (!mem.eql(u8, &expected, data[offset .. offset + 7])) return error.InvalidMessage;

    return .{
        .data = data,
        .len = expected.len,
        .message_type = .sup,
    };
}

pub fn message(self: *Self) Message {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

test "Hello" {
    const ServerClient = @import("../../server/ServerClient.zig");
    const posix = std.posix;

    const alloc = std.testing.allocator;

    {
        var msg = Self.init();

        const pipes = try posix.pipe();
        defer {
            posix.close(pipes[0]);
            posix.close(pipes[1]);
        }
        const server_client = try ServerClient.init(pipes[0]);
        server_client.sendMessage(alloc, msg.message());
    }
    {
        const bytes = [_]u8{
            @intFromEnum(MessageType.sup),
            @intFromEnum(MessageMagic.type_varchar),
            0x03,
            'V',
            'A',
            'X',
            @intFromEnum(MessageMagic.end),
        };
        var msg = try Self.fromBytes(&bytes, 0);

        const pipes = try posix.pipe();
        defer {
            posix.close(pipes[0]);
            posix.close(pipes[1]);
        }
        const server_client = try ServerClient.init(pipes[0]);
        server_client.sendMessage(alloc, msg.message());
    }
}
