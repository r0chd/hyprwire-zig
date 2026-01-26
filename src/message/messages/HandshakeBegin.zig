const std = @import("std");
const mem = std.mem;

const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;
const message_parser = @import("../MessageParser.zig");
const MessageType = @import("../MessageType.zig").MessageType;
const Message = @import("root.zig").Message;
const Error = @import("root.zig").Error;

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

versions: []const u32,
data: []const u8,
len: usize,
message_type: MessageType = .handshake_begin,

const Self = @This();

pub fn init(gpa: mem.Allocator, versions: []const u32) mem.Allocator.Error!Self {
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(gpa);

    try data.append(gpa, @intFromEnum(MessageType.handshake_begin));
    try data.append(gpa, @intFromEnum(MessageMagic.type_array));
    try data.append(gpa, @intFromEnum(MessageMagic.type_uint));

    var var_int_buf: [10]u8 = undefined;
    const var_int = message_parser.encodeVarInt(versions.len, &var_int_buf);
    for (var_int) |int| {
        try data.append(gpa, int);
    }

    for (versions) |version| {
        var ver_buf: [4]u8 = undefined;
        mem.writeInt(u32, &ver_buf, version, .little);
        try data.appendSlice(gpa, &ver_buf);
    }

    try data.append(gpa, @intFromEnum(MessageMagic.end));

    const data_slice = try data.toOwnedSlice(gpa);

    const versions_slice = try gpa.dupe(u32, versions);

    return .{
        .versions = versions_slice,
        .data = data_slice,
        .len = data_slice.len,
        .message_type = .handshake_begin,
    };
}

pub fn fromBytes(gpa: mem.Allocator, data: []const u8, offset: usize) (mem.Allocator.Error || Error)!Self {
    if (offset >= data.len) return Error.UnexpectedEof;
    if (data[offset] != @intFromEnum(MessageType.handshake_begin)) return Error.InvalidMessageType;

    var needle = offset + 1;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.type_array)) return Error.InvalidFieldType;
    needle += 1;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.type_uint)) return Error.InvalidFieldType;
    needle += 1;

    const parse_result = message_parser.parseVarInt(data, needle);
    const arr_len = parse_result[0];
    const var_int_len = parse_result[1];
    needle += var_int_len;

    if (needle + (arr_len * 4) > data.len) return Error.UnexpectedEof;

    const versions = try gpa.alloc(u32, arr_len);
    errdefer gpa.free(versions);

    for (0..arr_len) |i| {
        versions[i] = mem.readInt(u32, data[needle + (i * 4) ..][0..4], .little);
    }

    needle += arr_len * 4;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.end)) return Error.MalformedMessage;
    needle += 1;

    const message_len = needle - offset;

    return .{
        .versions = versions,
        .data = try gpa.dupe(u8, data[offset .. offset + message_len]),
        .len = message_len,
        .message_type = .handshake_begin,
    };
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    gpa.free(self.data);
    gpa.free(self.versions);
}

test "HandshakeBegin.init" {
    const messages = @import("./root.zig");
    const alloc = std.testing.allocator;

    const versions = [_]u32{ 1, 2 };
    var msg = try Self.init(alloc, &versions);
    defer msg.deinit(alloc);

    const data = try messages.parseData(Message.from(&msg), alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("handshake_begin ( { 1, 2 } ) ", data);
}

test "HandshakeBegin.fromBytes" {
    const messages = @import("./root.zig");
    const alloc = std.testing.allocator;

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
    var msg = try Self.fromBytes(alloc, &bytes, 0);
    defer msg.deinit(alloc);

    const data = try messages.parseData(Message.from(&msg), alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("handshake_begin ( { 1, 2 } ) ", data);
}
