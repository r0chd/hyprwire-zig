const std = @import("std");
const mem = std.mem;

const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;
const MessageType = @import("../MessageType.zig").MessageType;
const Message = @import("Message.zig");
const Error = Message.Error;

version: u32 = 0,
interface: Message,

const Self = @This();

pub fn init(gpa: mem.Allocator, version: u32) mem.Allocator.Error!Self {
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(gpa);

    try data.append(gpa, @intFromEnum(MessageType.handshake_ack));
    try data.append(gpa, @intFromEnum(MessageMagic.type_uint));
    var ver_buf: [4]u8 = undefined;
    mem.writeInt(u32, &ver_buf, version, .little);
    try data.appendSlice(gpa, &ver_buf);
    try data.append(gpa, @intFromEnum(MessageMagic.end));

    const owned = try data.toOwnedSlice(gpa);
    return .{
        .version = version,
        .interface = .{
            .data = owned,
            .len = owned.len,
            .message_type = .handshake_ack,
        },
    };
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    gpa.free(self.interface.data);
}

pub fn fromBytes(gpa: mem.Allocator, data: []const u8, offset: usize) (mem.Allocator.Error || Error)!Self {
    if (offset + 7 > data.len) return Error.UnexpectedEof;

    if (data[offset] != @intFromEnum(MessageType.handshake_ack)) return Error.InvalidMessageType;

    if (data[offset + 1] != @intFromEnum(MessageMagic.type_uint)) return Error.InvalidFieldType;

    var needle: usize = 2;

    if (data[offset + needle + 4] != @intFromEnum(MessageMagic.end)) return Error.MalformedMessage;

    const version = mem.readInt(u32, data[offset + 2 .. offset + 6][0..4], .little);

    needle += 4;

    const owned = try gpa.dupe(u8, data[offset .. offset + needle + 1]);
    return .{
        .version = version,
        .interface = .{
            .data = owned,
            .len = needle + 1,
            .message_type = .handshake_ack,
        },
    };
}

test "HandshakeAck.init" {
    const alloc = std.testing.allocator;

    var msg = try Self.init(alloc, 1);
    defer msg.deinit(alloc);

    const data = try msg.interface.parseData(alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("handshake_ack ( 1 ) ", data);
}

test "HandshakeAck.fromBytes" {
    const alloc = std.testing.allocator;

    // Message format: [type][UINT_magic][version:4][END]
    // version = 1 (0x01 0x00 0x00 0x00)
    const bytes = [_]u8{
        @intFromEnum(MessageType.handshake_ack),
        @intFromEnum(MessageMagic.type_uint),
        0x01,                           0x00, 0x00, 0x00, // version = 1
        @intFromEnum(MessageMagic.end),
    };
    var msg = try Self.fromBytes(alloc, &bytes, 0);
    defer msg.deinit(alloc);

    const data = try msg.interface.parseData(alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("handshake_ack ( 1 ) ", data);
}
