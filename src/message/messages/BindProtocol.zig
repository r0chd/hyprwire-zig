const std = @import("std");
const message_parser = @import("../MessageParser.zig");
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

data: []const u8,
len: usize,
message_type: MessageType = .bind_protocol,
seq: u32 = 0,
version: u32 = 0,
protocol: []const u8,

const Self = @This();

pub fn init(gpa: mem.Allocator, protocol: []const u8, seq: u32, version: u32) !Self {
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(gpa);

    try data.append(gpa, @intFromEnum(MessageType.bind_protocol));

    try data.append(gpa, @intFromEnum(MessageMagic.type_uint));
    try data.writer(gpa).writeInt(u32, seq, .little);

    try data.append(gpa, @intFromEnum(MessageMagic.type_varchar));
    try data.appendSlice(gpa, message_parser.message_parser.encodeVarInt(protocol.len));
    try data.appendSlice(gpa, protocol);

    try data.append(gpa, @intFromEnum(MessageMagic.type_uint));
    try data.writer(gpa).writeInt(u32, version, .little);

    try data.append(gpa, @intFromEnum(MessageMagic.end));

    return .{
        .len = data.items.len,
        .data = try data.toOwnedSlice(gpa),
        .message_type = .bind_protocol,
        .protocol = try gpa.dupe(u8, protocol),
    };
}

pub fn fromBytes(gpa: mem.Allocator, data: []const u8, offset: usize) !Self {
    if (offset >= data.len) return error.OutOfRange;
    if (data[offset] != @intFromEnum(MessageType.bind_protocol)) return error.InvalidMessage;

    var needle = offset + 1;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.type_uint)) return error.InvalidMessage;
    needle += 1;
    if (needle + 4 > data.len) return error.OutOfRange;
    const seq = mem.readInt(u32, data[needle..][0..4], .little);
    needle += 4;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.type_varchar)) return error.InvalidMessage;
    needle += 1;

    var protocol_len: usize = 0;
    var var_int_len: usize = 0;
    while (needle + var_int_len < data.len) : (var_int_len += 1) {
        const byte = data[needle + var_int_len];
        protocol_len |= @as(usize, byte & 0x7F) << @intCast(var_int_len * 7);
        if ((byte & 0x80) == 0) break;
        if (var_int_len >= 8) return error.InvalidMessage;
    }
    var_int_len += 1;
    needle += var_int_len;

    if (needle + protocol_len > data.len) return error.OutOfRange;
    const protocol_slice = data[needle .. needle + protocol_len];
    needle += protocol_len;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.type_uint)) return error.InvalidMessage;
    needle += 1;
    if (needle + 4 > data.len) return error.OutOfRange;
    const version = mem.readInt(u32, data[needle..][0..4], .little);
    if (version == 0) return error.InvalidMessage;
    needle += 4;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.end)) return error.InvalidMessage;
    needle += 1;

    return .{
        .data = if (isTrace()) try gpa.dupe(u8, data[offset .. offset + needle - offset]) else &[_]u8{},
        .len = needle - offset,
        .message_type = .bind_protocol,
        .seq = seq,
        .protocol = try gpa.dupe(u8, protocol_slice),
        .version = version,
    };
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    gpa.free(self.data);
    gpa.free(self.protocol);
}

test "BindProtocol.init" {
    const messages = @import("./root.zig");
    const alloc = std.testing.allocator;

    var msg = try Self.init(alloc, "test@1", 5, 1);
    defer msg.deinit(alloc);

    const data = try messages.parseData(Message.from(&msg), alloc);
    defer alloc.free(data);

    std.debug.assert(mem.eql(u8, data, "bind_protocol ( 5 )"));
}

test "BindProtocol.fromBytes" {
    const messages = @import("./root.zig");
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

    const data = try messages.parseData(Message.from(&msg), alloc);
    defer alloc.free(data);

    if (isTrace()) {
        std.debug.assert(mem.eql(u8, data, "bind_protocol ( 5 )"));
    } else {
        std.debug.assert(mem.eql(u8, data, "bind_protocol (  )"));
    }
}
