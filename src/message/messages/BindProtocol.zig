const std = @import("std");
const mem = std.mem;

const MessageMagic = @import("../../implementation/types.zig").MessageMagic;
const message_parser = @import("../MessageParser.zig");
const MessageType = @import("../MessageType.zig").MessageType;
const Message = @import("Message.zig");
const Error = Message.Error;

seq: u32 = 0,
version: u32 = 0,
protocol: []const u8,
interface: Message,

const Self = @This();

pub fn init(gpa: mem.Allocator, protocol: []const u8, seq: u32, version: u32) mem.Allocator.Error!Self {
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(gpa);

    try data.append(gpa, @intFromEnum(MessageType.bind_protocol));

    try data.append(gpa, @intFromEnum(MessageMagic.type_uint));
    var seq_buf: [4]u8 = undefined;
    mem.writeInt(u32, &seq_buf, seq, .little);
    try data.appendSlice(gpa, &seq_buf);

    try data.append(gpa, @intFromEnum(MessageMagic.type_varchar));
    var proto_len_buf: [10]u8 = undefined;
    const proto_len_int = message_parser.encodeVarInt(protocol.len, &proto_len_buf);
    try data.appendSlice(gpa, proto_len_int);
    try data.appendSlice(gpa, protocol);

    try data.append(gpa, @intFromEnum(MessageMagic.type_uint));
    var ver_buf: [4]u8 = undefined;
    mem.writeInt(u32, &ver_buf, version, .little);
    try data.appendSlice(gpa, &ver_buf);

    try data.append(gpa, @intFromEnum(MessageMagic.end));

    return .{
        .protocol = try gpa.dupe(u8, protocol),
        .interface = .{
            .len = data.items.len,
            .data = try data.toOwnedSlice(gpa),
            .message_type = .bind_protocol,
        },
    };
}

pub fn fromBytes(gpa: mem.Allocator, data: []const u8, offset: usize) (mem.Allocator.Error || Error)!Self {
    if (offset >= data.len) return Error.UnexpectedEof;
    if (data[offset] != @intFromEnum(MessageType.bind_protocol)) return Error.InvalidMessageType;

    var needle = offset + 1;

    if (needle >= data.len) return Error.UnexpectedEof;
    if (data[needle] != @intFromEnum(MessageMagic.type_uint)) return Error.InvalidFieldType;

    needle += 1;
    if (needle + 4 > data.len) return Error.UnexpectedEof;
    const seq = mem.readInt(u32, data[needle..][0..4], .little);
    needle += 4;

    if (needle >= data.len) return Error.UnexpectedEof;
    if (data[needle] != @intFromEnum(MessageMagic.type_varchar)) return Error.InvalidFieldType;

    needle += 1;

    var protocol_len: usize = 0;
    var var_int_len: usize = 0;
    while (needle + var_int_len < data.len) : (var_int_len += 1) {
        const byte = data[needle + var_int_len];
        protocol_len |= @as(usize, byte & 0x7F) << @intCast(var_int_len * 7);
        if ((byte & 0x80) == 0) break;
        if (var_int_len >= 8) return Error.InvalidVarInt;
    }
    var_int_len += 1;
    needle += var_int_len;

    if (needle + protocol_len > data.len) return Error.UnexpectedEof;
    const protocol_slice = data[needle .. needle + protocol_len];
    needle += protocol_len;

    if (needle >= data.len) return Error.UnexpectedEof;
    if (data[needle] != @intFromEnum(MessageMagic.type_uint)) return Error.InvalidFieldType;

    needle += 1;
    if (needle + 4 > data.len) return Error.UnexpectedEof;
    const version = mem.readInt(u32, data[needle..][0..4], .little);
    if (version == 0) return Error.InvalidVersion;
    needle += 4;

    if (needle >= data.len) return Error.UnexpectedEof;
    if (data[needle] != @intFromEnum(MessageMagic.end)) return Error.InvalidFieldType;

    needle += 1;

    const owned = try gpa.dupe(u8, data[offset .. offset + needle - offset]);

    return .{
        .seq = seq,
        .protocol = try gpa.dupe(u8, protocol_slice),
        .version = version,
        .interface = .{
            .data = owned,
            .len = needle - offset,
            .message_type = .bind_protocol,
        },
    };
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    gpa.free(self.protocol);
    gpa.free(self.interface.data);
}

test "BindProtocol.init" {
    const alloc = std.testing.allocator;

    var msg = try Self.init(alloc, "test@1", 5, 1);
    defer msg.deinit(alloc);

    const data = try msg.interface.parseData(alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("bind_protocol ( 5, \"test@1\", 1 ) ", data);
    try std.testing.expectEqualSlices(i32, msg.interface.getFds(), &.{});
}

test "BindProtocol.fromBytes" {
    const alloc = std.testing.allocator;

    // Message format: [type][UINT_magic][seq:4][VARCHAR_magic][varint_len][protocol][UINT_magic][version:4][END]
    // protocol = "test@1" (6 bytes), varint encoding of 6 = 0x06
    // seq = 5 (0x05 0x00 0x00 0x00)
    // version = 1 (0x01 0x00 0x00 0x00)
    const bytes = [_]u8{
        @intFromEnum(MessageType.bind_protocol),
        @intFromEnum(MessageMagic.type_uint),
        0x05,                                    0x00, 0x00, 0x00, // seq = 5
        @intFromEnum(MessageMagic.type_varchar),
        0x06, // varint length = 6
        't',                                  'e', 's', 't', '@', '1', // protocol = "test@1"
        @intFromEnum(MessageMagic.type_uint),
        0x01,                           0x00, 0x00, 0x00, // version = 1
        @intFromEnum(MessageMagic.end),
    };
    var msg = try Self.fromBytes(alloc, &bytes, 0);
    defer msg.deinit(alloc);
    try std.testing.expectEqual(msg.interface.len, bytes.len);

    const data = try msg.interface.parseData(alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("bind_protocol ( 5, \"test@1\", 1 ) ", data);
    try std.testing.expectEqualSlices(i32, msg.interface.getFds(), &.{});
}
