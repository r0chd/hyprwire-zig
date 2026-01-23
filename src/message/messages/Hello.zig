const std = @import("std");
const mem = std.mem;

const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;
const MessageType = @import("../MessageType.zig").MessageType;
const Message = @import("root.zig").Message;

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
        .data = data[offset .. offset + 7],
        .len = expected.len,
        .message_type = .sup,
    };
}

pub fn getFds(self: *Self) []const i32 {
    _ = self;

    return &.{};
}

pub fn getData(self: *Self) []const u8 {
    return self.data;
}

pub fn getLen(self: *Self) usize {
    return self.len;
}

pub fn getMessageType(self: *Self) MessageType {
    return self.message_type;
}

test "Hello.init" {
    const messages = @import("./root.zig");
    const alloc = std.testing.allocator;

    var msg = Self.init();

    const data = try messages.parseData(Message.from(&msg), alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("sup ( \"VAX\" ) ", data);
}

test "Hello.fromBytes" {
    const messages = @import("./root.zig");
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

    const data = try messages.parseData(Message.from(&msg), alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("sup ( \"VAX\" ) ", data);
}
