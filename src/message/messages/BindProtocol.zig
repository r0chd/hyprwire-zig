const std = @import("std");
const mem = std.mem;

const Message = @import("Message.zig");
const MessageType = @import("../MessageType.zig").MessageType;
const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;

base: Message,

const Self = @This();

pub fn init(gpa: mem.Allocator, protocol: []const u8, seq: u32, version: u32) !Self {
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(gpa);

    try data.append(gpa, @intFromEnum(MessageType.bind_protocol));

    try data.append(gpa, @intFromEnum(MessageMagic.type_uint));
    try data.writer(gpa).writeInt(u32, seq, .little);

    try data.append(gpa, @intFromEnum(MessageMagic.type_varchar));
    var protocol_len = protocol.len;
    while (protocol_len > 0x7F) {
        try data.append(gpa, @as(u8, @truncate(protocol_len & 0x7F)) | 0x80);
        protocol_len >>= 7;
    }
    try data.append(gpa, @as(u8, @truncate(protocol_len)));
    try data.appendSlice(gpa, protocol);

    try data.append(gpa, @intFromEnum(MessageMagic.type_uint));
    try data.writer(gpa).writeInt(u32, version, .little);

    try data.append(gpa, @intFromEnum(MessageMagic.end));

    const data_slice = try data.toOwnedSlice(gpa);

    return Self{
        .base = Message{
            .data = data_slice,
            .len = data_slice.len,
            .message_type = .bind_protocol,
        },
    };
}

pub fn fromBytes(data: []const u8, offset: usize) !Self {
    if (offset >= data.len) return error.OutOfRange;
    if (data[offset] != @intFromEnum(MessageType.bind_protocol)) return error.InvalidMessage;

    var needle = offset + 1;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.type_uint)) return error.InvalidMessage;
    needle += 1;
    if (needle + 4 > data.len) return error.OutOfRange;
    _ = mem.readInt(u32, data[needle..][0..4], .little);
    needle += 4;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.type_varchar)) return error.InvalidMessage;
    needle += 1;

    var protocol_len: usize = 0;
    var shift: u6 = 0;
    while (needle < data.len) {
        const byte = data[needle];
        protocol_len |= @as(usize, byte & 0x7F) << shift;
        needle += 1;
        if ((byte & 0x80) == 0) break;
        shift += 7;
        if (shift >= 64) return error.InvalidMessage;
    }

    if (needle + protocol_len > data.len) return error.OutOfRange;
    _ = data[needle..][0..protocol_len];
    needle += protocol_len;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.type_uint)) return error.InvalidMessage;
    needle += 1;
    if (needle + 4 > data.len) return error.OutOfRange;
    const version = mem.readInt(u32, data[needle..][0..4], .little);
    if (version == 0) return error.InvalidMessage;
    needle += 4;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.end)) return error.InvalidMessage;
    needle += 1;

    const message_len = needle - offset;

    return Self{
        .base = Message{
            .data = data[offset..],
            .len = message_len,
            .message_type = .bind_protocol,
        },
    };
}

pub fn fds(self: *const Self) []const i32 {
    _ = self;
    return &.{};
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    gpa.free(self.base.data);
}
