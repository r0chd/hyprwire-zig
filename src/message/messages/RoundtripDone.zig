const std = @import("std");
const mem = std.mem;

const MessageMagic = @import("../../implementation/types.zig").MessageMagic;
const MessageType = @import("../MessageType.zig").MessageType;
const Message = @import("Message.zig");
const Error = Message.Error;

seq: u32 = 0,
interface: Message,

const Self = @This();

pub fn init(gpa: mem.Allocator, seq: u32) mem.Allocator.Error!Self {
    var data: std.ArrayList(u8) = try .initCapacity(gpa, 7);
    errdefer data.deinit(gpa);

    try data.append(gpa, @intFromEnum(MessageType.roundtrip_done));
    try data.append(gpa, @intFromEnum(MessageMagic.type_uint));
    var seq_buf: [4]u8 = undefined;
    mem.writeInt(u32, &seq_buf, seq, .little);
    try data.appendSlice(gpa, &seq_buf);
    try data.append(gpa, @intFromEnum(MessageMagic.end));

    const owned = try data.toOwnedSlice(gpa);
    return .{
        .seq = seq,
        .interface = .{
            .data = owned,
            .len = owned.len,
            .message_type = .roundtrip_done,
        },
    };
}

pub fn fromBytes(gpa: mem.Allocator, data: []const u8, offset: usize) (mem.Allocator.Error || Error)!Self {
    if (offset + 7 > data.len) return Error.UnexpectedEof;

    if (data[offset] != @intFromEnum(MessageType.roundtrip_done)) return Error.InvalidMessageType;
    if (data[offset + 1] != @intFromEnum(MessageMagic.type_uint)) return Error.InvalidFieldType;

    const seq = mem.readInt(u32, data[offset + 2 ..][0..4], .little);

    if (data[offset + 6] != @intFromEnum(MessageMagic.end)) return Error.MalformedMessage;

    return .{
        .seq = seq,
        .interface = .{
            .data = try gpa.dupe(u8, data[offset..][0..7]),
            .len = 7,
            .message_type = .roundtrip_done,
        },
    };
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    gpa.free(self.interface.data);
}

test "RoundtripDone.init" {
    const alloc = std.testing.allocator;

    var msg = try Self.init(alloc, 42);
    defer msg.deinit(alloc);

    const data = try msg.interface.parseData(alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("roundtrip_done ( 42 ) ", data);
}

test "RoundtripDone.fromBytes" {
    const alloc = std.testing.allocator;

    // Message format: [type][UINT_magic][seq:4][END]
    // seq = 42 (0x2A 0x00 0x00 0x00)
    const bytes = [_]u8{
        @intFromEnum(MessageType.roundtrip_done),
        @intFromEnum(MessageMagic.type_uint),
        0x2A,                           0x00, 0x00, 0x00, // seq = 42
        @intFromEnum(MessageMagic.end),
    };
    var msg = try Self.fromBytes(alloc, &bytes, 0);
    defer msg.deinit(alloc);

    const data = try msg.interface.parseData(alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("roundtrip_done ( 42 ) ", data);
}
