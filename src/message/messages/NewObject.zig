const std = @import("std");

const mem = std.mem;

const MessageType = @import("../MessageType.zig").MessageType;
const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;

id: u32,
seq: u32,
data: []const u8,
message_type: MessageType = .invalid,
len: usize = 0,

const Self = @This();

pub fn init(seq: u32, id: u32) Self {
    var data = [_]u8{
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

    mem.writeInt(u32, data[2..6], id, .little);
    mem.writeInt(u32, data[7..11], seq, .little);

    return Self{
        .data = &data,
        .len = data.len,
        .message_type = .new_object,
        .id = id,
        .seq = seq,
    };
}

pub fn fromBytes(data: []const u8, offset: usize) !Self {
    if (offset + 12 > data.len)
        return error.OutOfRange;

    if (data[offset + 0] != @intFromEnum(MessageType.new_object))
        return error.InvalidMessage;

    if (data[offset + 1] != @intFromEnum(MessageMagic.type_uint))
        return error.InvalidMessage;

    const id = mem.readVarInt(u32, data[offset + 2 .. offset + 6], .little);

    if (data[offset + 6] != @intFromEnum(MessageMagic.type_uint))
        return error.InvalidMessage;

    const seq = mem.readVarInt(u32, data[offset + 7 .. offset + 11], .little);

    if (data[offset + 11] != @intFromEnum(MessageMagic.end))
        return error.InvalidMessage;

    return Self{
        .data = data[offset .. offset + 12],
        .len = 12,
        .message_type = .new_object,
        .id = id,
        .seq = seq,
    };
}

pub fn fds(self: *const Self) []const i32 {
    _ = self;
    return &.{};
}

test "NewObject" {
    const ServerClient = @import("../../server/ServerClient.zig");

    const alloc = std.testing.allocator;

    {
        const message = Self.init(3, 2);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
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
        const message = try Self.fromBytes(&bytes, 0);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
}
