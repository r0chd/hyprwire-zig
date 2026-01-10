const std = @import("std");
const mem = std.mem;

const Message = @import("Message.zig");
const MessageType = @import("../MessageType.zig").MessageType;
const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;

seq: u32 = 0,
base: Message,

const Self = @This();

pub fn init(seq: u32) Self {
    var data = [_]u8{
        @intFromEnum(MessageType.roundtrip_request),
        @intFromEnum(MessageMagic.type_uint),
        0,
        0,
        0,
        0,
        @intFromEnum(MessageMagic.end),
    };

    mem.writeInt(u32, data[2..6], seq, .little);

    return Self{
        .base = Message{
            .data = &data,
            .len = data.len,
            .message_type = .roundtrip_request,
        },
        .seq = seq,
    };
}

pub fn fromBytes(data: []const u8, offset: usize) !Self {
    if (offset + 7 > data.len) return error.OutOfRange;

    if (data[offset] != @intFromEnum(MessageType.roundtrip_request)) return error.InvalidMessage;

    if (data[offset + 1] != @intFromEnum(MessageMagic.type_uint)) return error.InvalidMessage;

    const seq = mem.readInt(u32, data[offset + 2 .. offset + 6][0..4], .little);

    if (data[offset + 6] != @intFromEnum(MessageMagic.end)) return error.InvalidMessage;

    return Self{
        .base = Message{
            .data = data[offset..],
            .len = 7,
            .message_type = .roundtrip_request,
        },
        .seq = seq,
    };
}

pub fn fds(self: *const Self) []const i32 {
    _ = self;
    return &.{};
}
