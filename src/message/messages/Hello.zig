const std = @import("std");
const mem = std.mem;

const MessageMagic = @import("../../implementation/types.zig").MessageMagic;
const MessageType = @import("../MessageType.zig").MessageType;
const Message = @import("Message.zig");
const Error = Message.Error;

interface: Message,

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
        .interface = .{
            .data = data,
            .len = data.len,
            .message_type = .sup,
        },
    };
}

pub fn fromBytes(data: []const u8, offset: usize) Error!Self {
    if (offset + 7 > data.len) return Error.UnexpectedEof;

    const expected = [_]u8{
        @intFromEnum(MessageType.sup),
        @intFromEnum(MessageMagic.type_varchar),
        0x03,
        'V',
        'A',
        'X',
        @intFromEnum(MessageMagic.end),
    };

    if (!mem.eql(u8, &expected, data[offset .. offset + 7])) return Error.MalformedMessage;

    return .{
        .interface = .{
            .data = data[offset .. offset + 7],
            .len = expected.len,
            .message_type = .sup,
        },
    };
}

test "Hello.init" {
    const alloc = std.testing.allocator;

    var msg = Self.init();

    const data = try msg.interface.parseData(alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("sup ( \"VAX\" ) ", data);
}

test "Hello.fromBytes" {
    const alloc = std.testing.allocator;

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

    const data = try msg.interface.parseData(alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("sup ( \"VAX\" ) ", data);
}
