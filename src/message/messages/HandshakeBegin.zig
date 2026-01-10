const std = @import("std");
const mem = std.mem;

const Message = @import("Message.zig");
const MessageType = @import("../MessageType.zig").MessageType;
const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;

versions: []const u32,
base: Message,

const Self = @This();

pub fn init(gpa: mem.Allocator, versions_list: []const u32) !Self {
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(gpa);

    try data.append(gpa, @intFromEnum(MessageType.handshake_begin));
    try data.append(gpa, @intFromEnum(MessageMagic.type_array));
    try data.append(gpa, @intFromEnum(MessageMagic.type_uint));

    var arr_len = versions_list.len;
    while (arr_len > 0x7F) {
        try data.append(gpa, @as(u8, @truncate(arr_len & 0x7F)) | 0x80);
        arr_len >>= 7;
    }
    try data.append(gpa, @as(u8, @truncate(arr_len)));

    for (versions_list) |version| {
        try data.writer(gpa).writeInt(u32, version, .little);
    }

    try data.append(gpa, @intFromEnum(MessageMagic.end));

    const data_slice = try data.toOwnedSlice(gpa);

    const versions_slice = try gpa.dupe(u32, versions_list);

    return Self{
        .base = Message{
            .data = data_slice,
            .len = data_slice.len,
            .message_type = .handshake_begin,
        },
        .versions = versions_slice,
    };
}

pub fn fromBytes(gpa: mem.Allocator, data: []const u8, offset: usize) !Self {
    if (offset >= data.len) return error.OutOfRange;
    if (data[offset] != @intFromEnum(MessageType.handshake_begin)) return error.InvalidMessage;

    var needle = offset + 1;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.type_array)) return error.InvalidMessage;
    needle += 1;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.type_uint)) return error.InvalidMessage;
    needle += 1;

    var arr_len: usize = 0;
    var shift: u6 = 0;
    while (needle < data.len) {
        const byte = data[needle];
        arr_len |= @as(usize, byte & 0x7F) << shift;
        needle += 1;
        if ((byte & 0x80) == 0) break;
        shift += 7;
        if (shift >= 64) return error.InvalidMessage;
    }

    if (needle + (arr_len * 4) > data.len) return error.OutOfRange;

    const versions_slice = try gpa.alloc(u32, arr_len);
    errdefer gpa.free(versions_slice);

    for (0..arr_len) |i| {
        versions_slice[i] = mem.readInt(u32, data[needle + (i * 4)..][0..4], .little);
    }

    needle += arr_len * 4;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.end)) return error.InvalidMessage;
    needle += 1;

    const message_len = needle - offset;

    return Self{
        .base = Message{
            .data = try gpa.dupe(u8, data[offset..]),
            .len = message_len,
            .message_type = .handshake_begin,
        },
        .versions = versions_slice,
    };
}

pub fn fds(self: *const Self) []const i32 {
    _ = self;
    return &.{};
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    gpa.free(self.versions);
    gpa.free(self.base.data);
}
