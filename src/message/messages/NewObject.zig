const std = @import("std");
const helpers = @import("helpers");

const mem = std.mem;
const isTrace = helpers.isTrace;

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

id: u32,
seq: u32,
data: []const u8,
len: usize,
message_type: MessageType = .new_object,

const Self = @This();

pub fn init(gpa: mem.Allocator, seq: u32, id: u32) !Self {
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(gpa);

    try data.append(gpa, @intFromEnum(MessageType.new_object));
    try data.append(gpa, @intFromEnum(MessageMagic.type_uint));
    var id_buf: [4]u8 = undefined;
    mem.writeInt(u32, &id_buf, id, .little);
    try data.appendSlice(gpa, &id_buf);
    try data.append(gpa, @intFromEnum(MessageMagic.type_uint));
    var seq_buf: [4]u8 = undefined;
    mem.writeInt(u32, &seq_buf, seq, .little);
    try data.appendSlice(gpa, &seq_buf);
    try data.append(gpa, @intFromEnum(MessageMagic.end));

    const owned = try data.toOwnedSlice(gpa);
    return .{
        .id = id,
        .seq = seq,
        .data = owned,
        .len = owned.len,
        .message_type = .new_object,
    };
}

pub fn fromBytes(gpa: mem.Allocator, data: []const u8, offset: usize) !Self {
    if (offset + 12 > data.len)
        return error.OutOfRange;

    if (data[offset + 0] != @intFromEnum(MessageType.new_object))
        return error.InvalidMessage;

    if (data[offset + 1] != @intFromEnum(MessageMagic.type_uint))
        return error.InvalidMessage;

    const id = mem.readInt(u32, data[offset + 2 .. offset + 2 + @sizeOf(u32)][0..@sizeOf(u32)], .little);

    if (data[offset + 6] != @intFromEnum(MessageMagic.type_uint))
        return error.InvalidMessage;

    const seq = mem.readInt(u32, data[offset + 7 .. offset + 7 + @sizeOf(u32)][0..@sizeOf(u32)], .little);

    if (data[offset + 11] != @intFromEnum(MessageMagic.end))
        return error.InvalidMessage;

    const owned = try gpa.dupe(u8, data[offset..][0..12]);

    return .{
        .id = id,
        .seq = seq,
        .data = owned,
        .len = 12,
        .message_type = .new_object,
    };
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    gpa.free(self.data);
}

test "NewObject.init" {
    const messages = @import("./root.zig");
    const alloc = std.testing.allocator;

    var msg = try Self.init(alloc, 3, 2);
    defer msg.deinit(alloc);

    const data = try messages.parseData(Message.from(&msg), alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("new_object ( 2, 3 ) ", data);
}

test "NewObject.fromBytes" {
    const messages = @import("./root.zig");
    const alloc = std.testing.allocator;

    const bytes = [_]u8{
        @intFromEnum(MessageType.new_object),
        @intFromEnum(MessageMagic.type_uint),
        0x03,                                 0x00, 0x00, 0x00, // id = 3
        @intFromEnum(MessageMagic.type_uint),
        0x02,                           0x00, 0x00, 0x00, // seq = 2
        @intFromEnum(MessageMagic.end),
    };
    var msg = try Self.fromBytes(alloc, &bytes, 0);
    defer msg.deinit(alloc);

    const data = try messages.parseData(Message.from(&msg), alloc);
    defer alloc.free(data);

    if (isTrace()) {
        try std.testing.expectEqualStrings("new_object ( 3, 2 ) ", data);
    } else {
        try std.testing.expectEqualStrings("new_object (  ) ", data);
    }
}
