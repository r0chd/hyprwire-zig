const std = @import("std");
const mem = std.mem;

const MessageType = @import("../MessageType.zig").MessageType;
const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;

seq: u32 = 0,
data: []const u8,
message_type: MessageType = .invalid,
len: usize = 0,

const Self = @This();

pub fn init(seq: u32) Self {
    var data = [_]u8{
        @intFromEnum(MessageType.roundtrip_done),
        @intFromEnum(MessageMagic.type_uint),
        0,
        0,
        0,
        0,
        @intFromEnum(MessageMagic.end),
    };

    mem.writeInt(u32, data[2..6], seq, .little);

    return Self{
        .data = &data,
        .len = data.len,
        .message_type = .roundtrip_done,
        .seq = seq,
    };
}

pub fn fromBytes(data: []const u8, offset: usize) !Self {
    if (offset + 7 > data.len) return error.OutOfRange;

    if (data[offset] != @intFromEnum(MessageType.roundtrip_done)) return error.InvalidMessage;

    if (data[offset + 1] != @intFromEnum(MessageMagic.type_uint)) return error.InvalidMessage;

    const seq = mem.readInt(u32, data[offset + 2 .. offset + 6][0..4], .little);

    if (data[offset + 6] != @intFromEnum(MessageMagic.end)) return error.InvalidMessage;

    return Self{
        .data = data[offset..],
        .len = 7,
        .message_type = .roundtrip_done,
        .seq = seq,
    };
}

pub fn fds(self: *const Self) []const i32 {
    _ = self;
    return &.{};
}

test "RoundtripDone" {
    const ServerClient = @import("../../server/ServerClient.zig");

    const alloc = std.testing.allocator;

    {
        const message = Self.init(42);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
    {
        // Message format: [type][UINT_magic][seq:4][END]
        // seq = 42 (0x2A 0x00 0x00 0x00)
        const bytes = [_]u8{
            @intFromEnum(MessageType.roundtrip_done),
            @intFromEnum(MessageMagic.type_uint),
            0x2A,                           0x00, 0x00, 0x00, // seq = 42
            @intFromEnum(MessageMagic.end),
        };
        const message = try Self.fromBytes(&bytes, 0);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
}
