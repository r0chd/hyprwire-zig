const std = @import("std");

const mem = std.mem;

const Message = @import("Message.zig");
const MessageType = @import("../MessageType.zig").MessageType;
const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;

base: Message,

const Self = @This();

pub fn init() Self {
    const hello_data = &.{
        @intFromEnum(MessageType.sup),
        @intFromEnum(MessageMagic.type_varchar),
        0x03,
        'V',
        'A',
        'X',
        @intFromEnum(MessageMagic.end),
    };

    return Self{
        .base = Message{
            .data = hello_data,
            .len = hello_data.len,
            .message_type = .sup,
        },
    };
}

pub fn initFromBytes(data: []const u8, offset: usize) ?Self {
    if (offset + 7 > data.len) return null;

    const expected = [_]u8{
        @intFromEnum(MessageType.sup),
        @intFromEnum(MessageMagic.type_varchar),
        0x03,
        'V',
        'A',
        'X',
        @intFromEnum(MessageMagic.end),
    };

    if (!mem.eql(u8, &expected, data[offset .. offset + 7])) return null;

    return Self{
        .base = Message{ .data = data, .len = expected.len, .message_type = .sup },
    };
}

pub fn fds(self: *const Self) []const i32 {
    _ = self;
    return &.{};
}
