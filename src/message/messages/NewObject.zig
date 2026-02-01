const std = @import("std");
const mem = std.mem;

const MessageMagic = @import("../../implementation/types.zig").MessageMagic;
const MessageType = @import("../MessageType.zig").MessageType;
const Message = @import("Message.zig");
const Error = Message.Error;

id: u32,
seq: u32,
interface: Message,

const Self = @This();

pub fn init(gpa: mem.Allocator, seq: u32, id: u32) mem.Allocator.Error!Self {
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
        .interface = .{
            .data = owned,
            .len = owned.len,
            .message_type = .new_object,
        },
    };
}

pub fn fromBytes(gpa: mem.Allocator, data: []const u8, offset: usize) (mem.Allocator.Error || Error)!Self {
    if (offset + 12 > data.len)
        return Error.UnexpectedEof;

    if (data[offset + 0] != @intFromEnum(MessageType.new_object))
        return Error.InvalidMessageType;

    if (data[offset + 1] != @intFromEnum(MessageMagic.type_uint))
        return Error.InvalidFieldType;

    const id = mem.readInt(u32, data[offset + 2 .. offset + 2 + @sizeOf(u32)][0..@sizeOf(u32)], .little);

    if (data[offset + 6] != @intFromEnum(MessageMagic.type_uint))
        return Error.InvalidFieldType;

    const seq = mem.readInt(u32, data[offset + 7 .. offset + 7 + @sizeOf(u32)][0..@sizeOf(u32)], .little);

    if (data[offset + 11] != @intFromEnum(MessageMagic.end))
        return Error.MalformedMessage;

    return .{
        .id = id,
        .seq = seq,
        .interface = .{
            .data = try gpa.dupe(u8, data[offset..][0..12]),
            .len = 12,
            .message_type = .new_object,
        },
    };
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    gpa.free(self.interface.data);
}

test "NewObject.init" {
    const alloc = std.testing.allocator;

    var msg = try Self.init(alloc, 3, 2);
    defer msg.deinit(alloc);

    const data = try msg.interface.parseData(alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("new_object ( 2, 3 ) ", data);
}

test "NewObject.fromBytes" {
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

    const data = try msg.interface.parseData(alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("new_object ( 3, 2 ) ", data);
    try std.testing.expectEqual(msg.interface.len, 12);
    try std.testing.expectEqualSlices(i32, msg.interface.getFds(), &.{});
}

test "NewObject errors" {
    const alloc = std.testing.allocator;
    const testing = std.testing;

    {
        const bytes = [_]u8{
            @intFromEnum(MessageType.bind_protocol),
            @intFromEnum(MessageMagic.type_uint),
            0x03,                                 0x00, 0x00, 0x00, // id = 3
            @intFromEnum(MessageMagic.type_uint),
            0x02,                           0x00, 0x00, 0x00, // seq = 2
            @intFromEnum(MessageMagic.end),
        };
        const msg = Self.fromBytes(alloc, &bytes, 0);
        try testing.expectError(Error.InvalidMessageType, msg);
    }

    {
        const bytes = [_]u8{
            @intFromEnum(MessageType.new_object),
            @intFromEnum(MessageMagic.type_int),
            0x03,                                 0x00, 0x00, 0x00, // id = 3
            @intFromEnum(MessageMagic.type_uint),
            0x02,                           0x00, 0x00, 0x00, // seq = 2
            @intFromEnum(MessageMagic.end),
        };
        const msg = Self.fromBytes(alloc, &bytes, 0);
        try testing.expectError(Error.InvalidFieldType, msg);
    }

    {
        const bytes = [_]u8{
            @intFromEnum(MessageType.new_object),
            @intFromEnum(MessageMagic.type_uint),
            0x03,                                0x00, 0x00, 0x00, // id = 3
            @intFromEnum(MessageMagic.type_int),
            0x02,                           0x00, 0x00, 0x00, // seq = 2
            @intFromEnum(MessageMagic.end),
        };
        const msg = Self.fromBytes(alloc, &bytes, 0);
        try testing.expectError(Error.InvalidFieldType, msg);
    }

    {
        const bytes = [_]u8{
            @intFromEnum(MessageType.new_object),
            @intFromEnum(MessageMagic.type_uint),
            0x03,                                 0x00, 0x00, 0x00, // id = 3
            @intFromEnum(MessageMagic.type_uint),
            0x02,                                 0x00, 0x00, 0x00, // seq = 2
            @intFromEnum(MessageMagic.type_uint),
        };
        const msg = Self.fromBytes(alloc, &bytes, 0);
        try testing.expectError(Error.MalformedMessage, msg);
    }

    {
        const bytes = [_]u8{
            @intFromEnum(MessageType.new_object),
            @intFromEnum(MessageMagic.type_uint),
            0x03,                                 0x00, 0x00, 0x00, // id = 3
            @intFromEnum(MessageMagic.type_uint),
            0x02, 0x00, 0x00, 0x00, // seq = 2
        };
        const msg = Self.fromBytes(alloc, &bytes, 0);
        try testing.expectError(Error.UnexpectedEof, msg);
    }
}
