const std = @import("std");

const mem = std.mem;

const MessageType = @import("../MessageType.zig").MessageType;
const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;
const Message = @import("root.zig").Message;

pub fn getFds(self: *const Self) []const i32 {
    _ = self;
    return &.{};
}

pub fn getData(self: *const Self) []const u8 {
    return self.data;
}

pub fn getLen(self: *const Self) usize {
    return self.len;
}

pub fn getMessageType(self: *const Self) MessageType {
    return self.message_type;
}

id: u32,
seq: u32,
data: []const u8,
len: usize,
message_type: MessageType = .new_object,

const Self = @This();

pub fn init(seq: u32, id: u32) Self {
    var data_array = [_]u8{
        @intFromEnum(MessageType.new_object),
        @intFromEnum(MessageMagic.type_uint),
        0,
        0,
        0,
        0,
        @intFromEnum(MessageMagic.type_uint),
        0,
        0,
        0,
        0,
        @intFromEnum(MessageMagic.end),
    };

    mem.writeInt(u32, data_array[2..6], id, .little);
    mem.writeInt(u32, data_array[7..11], seq, .little);

    return .{
        .id = id,
        .seq = seq,
        .data = &data_array,
        .len = data_array.len,
        .message_type = .new_object,
    };
}

pub fn fromBytes(data: []const u8, offset: usize) !Self {
    if (offset + 12 > data.len)
        return error.OutOfRange;

    if (data[offset + 0] != @intFromEnum(MessageType.new_object))
        return error.InvalidMessage;

    if (data[offset + 1] != @intFromEnum(MessageMagic.type_uint))
        return error.InvalidMessage;

    const id = mem.readInt(u32, data[offset + 2 .. offset + 6][0..4], .little);

    if (data[offset + 6] != @intFromEnum(MessageMagic.type_uint))
        return error.InvalidMessage;

    const seq = mem.readInt(u32, data[offset + 7 .. offset + 11][0..4], .little);

    if (data[offset + 11] != @intFromEnum(MessageMagic.end))
        return error.InvalidMessage;

    return .{
        .id = id,
        .seq = seq,
        .data = data[offset..][0..12],
        .len = 12,
        .message_type = .new_object,
    };
}

test "NewObject" {
    const ServerClient = @import("../../server/ServerClient.zig");
    const posix = std.posix;

    const alloc = std.testing.allocator;

    {
        var msg = Self.init(3, 2);

        const pipes = try posix.pipe();
        defer {
            posix.close(pipes[0]);
            posix.close(pipes[1]);
        }
        const server_client = try ServerClient.init(pipes[0]);
        server_client.sendMessage(alloc, Message.from(&msg));
    }
    {
        const bytes = [_]u8{
            @intFromEnum(MessageType.new_object),
            @intFromEnum(MessageMagic.type_uint),
            0x03,                                 0x00, 0x00, 0x00, // id = 3
            @intFromEnum(MessageMagic.type_uint),
            0x02,                           0x00, 0x00, 0x00, // seq = 2
            @intFromEnum(MessageMagic.end),
        };
        var msg = try Self.fromBytes(&bytes, 0);

        const pipes = try posix.pipe();
        defer {
            posix.close(pipes[0]);
            posix.close(pipes[1]);
        }
        const server_client = try ServerClient.init(pipes[0]);
        server_client.sendMessage(alloc, Message.from(&msg));
    }
}
