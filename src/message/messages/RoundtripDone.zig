const std = @import("std");
const helpers = @import("helpers");

const isTrace = helpers.isTrace;
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

seq: u32 = 0,
data: []const u8,
len: usize,
message_type: MessageType = .roundtrip_done,

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

    return .{
        .seq = seq,
        .data = &data,
        .len = data.len,
        .message_type = .roundtrip_done,
    };
}

pub fn fromBytes(data: []const u8, offset: usize) !Self {
    if (offset + 7 > data.len) return error.OutOfRange;

    if (data[offset] != @intFromEnum(MessageType.roundtrip_done)) return error.InvalidMessage;
    if (data[offset + 1] != @intFromEnum(MessageMagic.type_uint)) return error.InvalidMessage;

    const seq = mem.readInt(u32, data[offset + 2 ..][0..4], .little);

    if (data[offset + 6] != @intFromEnum(MessageMagic.end)) return error.InvalidMessage;

    return .{
        .seq = seq,
        .data = if (isTrace()) data[offset..][0..6] else &[_]u8{},
        .len = 7,
        .message_type = .roundtrip_done,
    };
}

test "RoundtripDone.init" {
    const messages = @import("./root.zig");
    const alloc = std.testing.allocator;

    var msg = Self.init(42);

    const data = try messages.parseData(Message.from(&msg), alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("roundtrip_done ( 42 )", data);
}

test "RoundtripDone.fromBytes" {
    const messages = @import("./root.zig");
    const alloc = std.testing.allocator;

    // Message format: [type][UINT_magic][seq:4][END]
    // seq = 42 (0x2A 0x00 0x00 0x00)
    const bytes = [_]u8{
        @intFromEnum(MessageType.roundtrip_done),
        @intFromEnum(MessageMagic.type_uint),
        0x2A,                           0x00, 0x00, 0x00, // seq = 42
        @intFromEnum(MessageMagic.end),
    };
    var msg = try Self.fromBytes(&bytes, 0);

    const data = try messages.parseData(Message.from(&msg), alloc);
    defer alloc.free(data);

    if (isTrace()) {
        try std.testing.expectEqualStrings("roundtrip_done ( 42 )", data);
    } else {
        try std.testing.expectEqualStrings("roundtrip_done (  )", data);
    }
}
