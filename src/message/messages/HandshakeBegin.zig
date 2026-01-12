const std = @import("std");
const mem = std.mem;

const MessageType = @import("../MessageType.zig").MessageType;
const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;

versions: []const u32,
data: []const u8,
message_type: MessageType = .invalid,
len: usize = 0,

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
        .data = data_slice,
        .len = data_slice.len,
        .message_type = .handshake_begin,
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
        versions_slice[i] = mem.readInt(u32, data[needle + (i * 4) ..][0..4], .little);
    }

    needle += arr_len * 4;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.end)) return error.InvalidMessage;
    needle += 1;

    const message_len = needle - offset;

    return Self{
        .data = try gpa.dupe(u8, data[offset..]),
        .len = message_len,
        .message_type = .handshake_begin,
        .versions = versions_slice,
    };
}

pub fn fds(self: *const Self) []const i32 {
    _ = self;
    return &.{};
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    gpa.free(self.versions);
    gpa.free(self.data);
}

test "HandshakeBegin" {
    const ServerClient = @import("../../server/ServerClient.zig");

    const alloc = std.testing.allocator;

    {
        const versions = [_]u32{ 1, 2 };
        var message = try Self.init(alloc, &versions);
        defer message.deinit(alloc);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
    {
        // Message format: [type][ARRAY_magic][UINT_magic][varint_arr_len][version1:4][version2:4]...[END]
        // Array length = 2 (0x02)
        // version1 = 1 (0x01 0x00 0x00 0x00)
        // version2 = 2 (0x02 0x00 0x00 0x00)
        const bytes = [_]u8{
            @intFromEnum(MessageType.handshake_begin),
            @intFromEnum(MessageMagic.type_array),
            @intFromEnum(MessageMagic.type_uint),
            0x02, // array length = 2
            0x01, 0x00, 0x00, 0x00, // version = 1
            0x02,                           0x00, 0x00, 0x00, // version = 2
            @intFromEnum(MessageMagic.end),
        };
        var message = try Self.fromBytes(alloc, &bytes, 0);
        defer message.deinit(alloc);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
}
