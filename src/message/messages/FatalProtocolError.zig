const std = @import("std");
const mem = std.mem;

const Message = @import("Message.zig");
const MessageType = @import("../MessageType.zig").MessageType;
const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;

object_id: u32 = 0,
error_id: u32 = 0,
error_msg: []const u8,
base: Message,

const Self = @This();

// TODO: rething error_id
pub fn init(gpa: mem.Allocator, object_id: u32, error_id: u32, error_msg: []const u8) !Self {
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(gpa);

    try data.append(gpa, @intFromEnum(MessageType.fatal_protocol_error));
    try data.append(gpa, @intFromEnum(MessageMagic.type_uint));
    try data.writer(gpa).writeInt(u32, object_id, .little);

    try data.append(gpa, @intFromEnum(MessageMagic.type_uint));
    try data.writer(gpa).writeInt(u32, error_id, .little);

    try data.append(gpa, @intFromEnum(MessageMagic.type_varchar));
    var msg_len = error_msg.len;
    while (msg_len > 0x7F) {
        try data.append(gpa, @as(u8, @truncate(msg_len & 0x7F)) | 0x80);
        msg_len >>= 7;
    }
    try data.append(gpa, @as(u8, @truncate(msg_len)));
    try data.appendSlice(gpa, error_msg);

    try data.append(gpa, @intFromEnum(MessageMagic.end));

    const data_slice = try data.toOwnedSlice(gpa);

    const error_msg_copy = try gpa.dupe(u8, error_msg);

    return Self{
        .base = Message{
            .data = data_slice,
            .len = data_slice.len,
            .message_type = .fatal_protocol_error,
        },
        .object_id = object_id,
        .error_id = error_id,
        .error_msg = error_msg_copy,
    };
}

pub fn fromBytes(gpa: mem.Allocator, data: []const u8, offset: usize) !Self {
    if (offset >= data.len) return error.OutOfRange;
    if (data[offset] != @intFromEnum(MessageType.fatal_protocol_error)) return error.InvalidMessage;

    var needle = offset + 1;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.type_uint)) return error.InvalidMessage;
    needle += 1;
    if (needle + 4 > data.len) return error.OutOfRange;
    const object_id = mem.readInt(u32, data[needle..][0..4], .little);
    needle += 4;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.type_uint)) return error.InvalidMessage;
    needle += 1;
    if (needle + 4 > data.len) return error.OutOfRange;
    const error_id = mem.readInt(u32, data[needle..][0..4], .little);
    needle += 4;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.type_varchar)) return error.InvalidMessage;
    needle += 1;

    var msg_len: usize = 0;
    var shift: u6 = 0;
    while (needle < data.len) {
        const byte = data[needle];
        msg_len |= @as(usize, byte & 0x7F) << shift;
        needle += 1;
        if ((byte & 0x80) == 0) break;
        shift += 7;
        if (shift >= 64) return error.InvalidMessage;
    }

    if (needle + msg_len > data.len) return error.OutOfRange;
    const error_msg_copy = try gpa.dupe(u8, data[needle..][0..msg_len]);
    needle += msg_len;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.end)) return error.InvalidMessage;
    needle += 1;

    const message_len = needle - offset;

    return Self{
        .base = Message{
            .data = try gpa.dupe(u8, data[offset..]),
            .len = message_len,
            .message_type = .fatal_protocol_error,
        },
        .object_id = object_id,
        .error_id = error_id,
        .error_msg = error_msg_copy,
    };
}

pub fn fds(self: *const Self) []const i32 {
    _ = self;
    return &.{};
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    gpa.free(self.error_msg);
    gpa.free(self.base.data);
}
