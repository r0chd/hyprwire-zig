const std = @import("std");
const mem = std.mem;

const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;
const MessageType = @import("../MessageType.zig").MessageType;
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

object_id: u32 = 0,
error_id: u32 = 0,
error_msg: []const u8,
data: []const u8,
len: usize,
message_type: MessageType = .fatal_protocol_error,

const Self = @This();

pub fn init(gpa: mem.Allocator, object_id: u32, error_id: u32, error_msg: []const u8) !Self {
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(gpa);

    try data.append(gpa, @intFromEnum(MessageType.fatal_protocol_error));
    try data.append(gpa, @intFromEnum(MessageMagic.type_uint));
    var object_id_buf: [4]u8 = undefined;
    mem.writeInt(u32, &object_id_buf, object_id, .little);
    try data.appendSlice(gpa, &object_id_buf);

    try data.append(gpa, @intFromEnum(MessageMagic.type_uint));
    var error_id_buf: [4]u8 = undefined;
    mem.writeInt(u32, &error_id_buf, error_id, .little);
    try data.appendSlice(gpa, &error_id_buf);

    try data.append(gpa, @intFromEnum(MessageMagic.type_varchar));
    var msg_len = error_msg.len;
    while (msg_len > 0x7F) {
        try data.append(gpa, @as(u8, @truncate(msg_len & 0x7F)) | 0x80);
        msg_len >>= 7;
    }
    try data.append(gpa, @as(u8, @truncate(msg_len)));
    try data.appendSlice(gpa, error_msg);

    try data.append(gpa, @intFromEnum(MessageMagic.end));

    return .{
        .object_id = object_id,
        .error_id = error_id,
        .error_msg = try gpa.dupe(u8, error_msg),
        .len = data.items.len,
        .data = try data.toOwnedSlice(gpa),
        .message_type = .fatal_protocol_error,
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

    return Self{
        .data = try gpa.dupe(u8, data[offset..needle]),
        .len = needle - offset,
        .message_type = .fatal_protocol_error,
        .object_id = object_id,
        .error_id = error_id,
        .error_msg = error_msg_copy,
    };
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    gpa.free(self.error_msg);
    gpa.free(self.data);
}

test "FatalProtocolError.init" {
    const messages = @import("./root.zig");
    const alloc = std.testing.allocator;

    var msg = try Self.init(alloc, 3, 5, "test error");
    defer msg.deinit(alloc);

    const data = try messages.parseData(Message.from(&msg), alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("fatal_protocol_error ( 3, 5, \"test error\" ) ", data);
}

test "FatalProtocolError.fromBytes" {
    const messages = @import("./root.zig");
    const alloc = std.testing.allocator;

    // Message format: [type][UINT_magic][objectId:4][UINT_magic][errorId:4][VARCHAR_magic][varint_len][errorMsg][END]
    // objectId = 3 (0x03 0x00 0x00 0x00)
    // errorId = 5 (0x05 0x00 0x00 0x00)
    // errorMsg = "test error" (10 bytes, varint = 0x0A)
    const bytes = [_]u8{
        @intFromEnum(MessageType.fatal_protocol_error),
        @intFromEnum(MessageMagic.type_uint),
        0x03,                                 0x00, 0x00, 0x00, // objectId = 3
        @intFromEnum(MessageMagic.type_uint),
        0x05,                                    0x00, 0x00, 0x00, // errorId = 5
        @intFromEnum(MessageMagic.type_varchar),
        0x0A, // errorMsg length = 10
        't',                            'e', 's', 't', ' ', 'e', 'r', 'r', 'o', 'r', // "test error"
        @intFromEnum(MessageMagic.end),
    };
    var msg = try Self.fromBytes(alloc, &bytes, 0);
    defer msg.deinit(alloc);

    const data = try messages.parseData(Message.from(&msg), alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("fatal_protocol_error ( 3, 5, \"test error\" ) ", data);
}
