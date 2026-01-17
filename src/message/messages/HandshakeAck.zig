const std = @import("std");
const mem = std.mem;

const MessageType = @import("../MessageType.zig").MessageType;
const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;
const Message = @import("root.zig").Message;
const helpers = @import("helpers");
const isTrace = helpers.isTrace;

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

version: u32 = 0,
data: []const u8,
len: usize,
message_type: MessageType = .handshake_ack,

const Self = @This();

pub fn init(version: u32) Self {
    var data_array = [_]u8{
        @intFromEnum(MessageType.handshake_ack),
        @intFromEnum(MessageMagic.type_uint),
        0,
        0,
        0,
        0,
        @intFromEnum(MessageMagic.end),
    };

    mem.writeInt(u32, data_array[2..6], version, .little);

    return .{
        .version = version,
        .data = &data_array,
        .len = data_array.len,
        .message_type = .handshake_ack,
    };
}

pub fn fromBytes(data: []const u8, offset: usize) !Self {
    if (offset + 7 > data.len) return error.OutOfRange;

    if (data[offset] != @intFromEnum(MessageType.handshake_ack)) return error.InvalidMessage;

    if (data[offset + 1] != @intFromEnum(MessageMagic.type_uint)) return error.InvalidMessage;

    var needle: usize = 2;

    if (data[offset + needle + 4] != @intFromEnum(MessageMagic.end)) return error.InvalidMessage;

    const version = mem.readInt(u32, data[offset + 2 .. offset + 6][0..4], .little);

    needle += 4;

    return .{
        .version = version,
        .data = if (isTrace()) data[offset .. offset + needle + 1] else &[_]u8{},
        .len = needle + 1,
        .message_type = .handshake_ack,
    };
}

test "HandshakeAck.init" {
    const messages = @import("./root.zig");
    const alloc = std.testing.allocator;

    var msg = Self.init(1);

    const data = try messages.parseData(Message.from(&msg), alloc);
    defer alloc.free(data);

    std.debug.assert(mem.eql(u8, data, "handshake_ack ( 1 )"));
}

test "HandshakeAck.fromBytes" {
    const messages = @import("./root.zig");
    const alloc = std.testing.allocator;

    // Message format: [type][UINT_magic][version:4][END]
    // version = 1 (0x01 0x00 0x00 0x00)
    const bytes = [_]u8{
        @intFromEnum(MessageType.handshake_ack),
        @intFromEnum(MessageMagic.type_uint),
        0x01,                           0x00, 0x00, 0x00, // version = 1
        @intFromEnum(MessageMagic.end),
    };
    var msg = try Self.fromBytes(&bytes, 0);

    const data = try messages.parseData(Message.from(&msg), alloc);
    defer alloc.free(data);

    if (isTrace()) {
        std.debug.assert(mem.eql(u8, data, "handshake_ack ( 1 )"));
    } else {
        std.debug.assert(mem.eql(u8, data, "handshake_ack (  )"));
    }
}
