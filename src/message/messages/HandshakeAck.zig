const std = @import("std");
const mem = std.mem;

const MessageType = @import("../MessageType.zig").MessageType;
const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;

version: u32 = 0,
data: []const u8,
message_type: MessageType = .invalid,
len: usize = 0,

const Self = @This();

pub fn init(version: u32) Self {
    var data = [_]u8{
        @intFromEnum(MessageType.handshake_ack),
        @intFromEnum(MessageMagic.type_uint),
        0,
        0,
        0,
        0,
        @intFromEnum(MessageMagic.end),
    };

    mem.writeInt(u32, data[2..6], version, .little);

    return Self{
        .data = &data,
        .len = data.len,
        .message_type = .handshake_ack,
        .version = version,
    };
}

pub fn fromBytes(data: []const u8, offset: usize) !Self {
    if (offset + 7 > data.len) return error.OutOfRange;

    if (data[offset] != @intFromEnum(MessageType.handshake_ack)) return error.InvalidMessage;

    if (data[offset + 1] != @intFromEnum(MessageMagic.type_uint)) return error.InvalidMessage;

    const version = mem.readInt(u32, data[offset + 2 .. offset + 6][0..4], .little);

    if (data[offset + 6] != @intFromEnum(MessageMagic.end)) return error.InvalidMessage;

    return Self{
        .data = data[offset..],
        .len = 7,
        .message_type = .handshake_ack,
        .version = version,
    };
}

pub fn fds(self: *const Self) []const i32 {
    _ = self;
    return &.{};
}

test "HandshakeAck" {
    const ServerClient = @import("../../server/ServerClient.zig");

    const alloc = std.testing.allocator;

    {
        const message = Self.init(1);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
    {
        // Message format: [type][UINT_magic][version:4][END]
        // version = 1 (0x01 0x00 0x00 0x00)
        const bytes = [_]u8{
            @intFromEnum(MessageType.handshake_ack),
            @intFromEnum(MessageMagic.type_uint),
            0x01,                           0x00, 0x00, 0x00, // version = 1
            @intFromEnum(MessageMagic.end),
        };
        const message = try Self.fromBytes(&bytes, 0);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
}
