const std = @import("std");
const message_parser = @import("../MessageParser.zig");

const mem = std.mem;

const MessageType = @import("../MessageType.zig").MessageType;
const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;
const Message = @import("root.zig").Message;
const helpers = @import("helpers");
const isTrace = helpers.isTrace;

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

protocols: []const []const u8,
data: []const u8,
len: usize,
message_type: MessageType = .handshake_protocols,

const Self = @This();

pub fn init(gpa: mem.Allocator, protocols: []const []const u8) !Self {
    var data: std.ArrayList(u8) = .empty;

    try data.appendSlice(gpa, &.{
        @intFromEnum(MessageType.handshake_protocols),
        @intFromEnum(MessageMagic.type_array),
        @intFromEnum(MessageMagic.type_varchar),
    });

    try data.appendSlice(gpa, message_parser.message_parser.encodeVarInt(protocols.len));

    for (protocols) |protocol| {
        try data.appendSlice(gpa, message_parser.message_parser.encodeVarInt(protocol.len));
        try data.appendSlice(gpa, protocol);
    }

    try data.append(gpa, @intFromEnum(MessageMagic.end));

    const data_slice = try data.toOwnedSlice(gpa);

    return .{
        .protocols = try gpa.dupe([]const u8, protocols),
        .data = data_slice,
        .len = data_slice.len,
        .message_type = .handshake_protocols,
    };
}

pub fn fromBytes(gpa: mem.Allocator, data: []const u8, offset: usize) !Self {
    if (offset >= data.len) return error.OutOfRange;

    if (data[offset + 0] != @intFromEnum(MessageType.handshake_protocols)) return error.InvalidMessage;
    if (data[offset + 1] != @intFromEnum(MessageMagic.type_array)) return error.InvalidMessage;
    if (data[offset + 2] != @intFromEnum(MessageMagic.type_varchar)) return error.InvalidMessage;

    var needle: usize = 3;

    const res = message_parser.message_parser.parseVarInt(data, offset + needle);
    needle += res.@"1";

    var protocols: std.ArrayList([]const u8) = try .initCapacity(gpa, res.@"0");
    errdefer protocols.deinit(gpa);

    for (0..res.@"0") |_| {
        if (offset + needle >= data.len) return error.OutOfRange;

        const r = message_parser.message_parser.parseVarInt(data, offset + needle);

        if (offset + needle + r.@"1" + r.@"0" > data.len) return error.OutOfRange;

        const protocol_slice = data[offset + needle + r.@"1" .. offset + needle + r.@"1" + r.@"0"];
        protocols.appendAssumeCapacity(protocol_slice);
        needle += r.@"0" + r.@"1";
    }

    if (data[offset + needle] != @intFromEnum(MessageMagic.end)) return error.InvalidMessage;

    const len = needle + 1;

    return .{
        .protocols = try protocols.toOwnedSlice(gpa),
        .data = if (isTrace()) try gpa.dupe(u8, data[offset .. offset + len]) else &[_]u8{},
        .len = len,
        .message_type = .handshake_protocols,
    };
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    gpa.free(self.data);
    gpa.free(self.protocols);
}

test "HandshakeProtocols.init" {
    const messages = @import("./root.zig");
    const alloc = std.testing.allocator;

    const protocols = [_][]const u8{ "test@1", "test@2" };
    var msg = try Self.init(alloc, &protocols);
    defer msg.deinit(alloc);

    const data = try messages.parseData(Message.from(&msg), alloc);
    defer alloc.free(data);

    std.debug.assert(mem.eql(u8, data, "handshake_protocols ( { \"test@1\", \"test@2\" } )"));
}

test "HandshakeProtocols.fromBytes" {
    const messages = @import("./root.zig");
    const alloc = std.testing.allocator;

    // Message format: [type][ARRAY_magic][VARCHAR_magic][varint_arr_len][varint_str_len][str]...[END]
    // Array length = 1 (0x01)
    // String: "test@12" (7 bytes, varint = 0x07)
    const bytes = [_]u8{
        4,
        33,
        32,
        0x02, // array length = 2
        0x06, // string length = 6
        't', 'e', 's', 't', '@', '1', // "test@1"
        0x06, // string length = 6
        't', 'e', 's', 't', '@', '2', // "test@2"
        0,
    };

    var msg = try Self.fromBytes(alloc, &bytes, 0);
    defer msg.deinit(alloc);

    const data = try messages.parseData(Message.from(&msg), alloc);
    defer alloc.free(data);

    if (isTrace()) {
        std.debug.assert(mem.eql(u8, data, "handshake_protocols ( { \"test@1\", \"test@2\" } )"));
    } else {
        std.debug.assert(mem.eql(u8, data, "handshake_protocols (  )"));
    }
}
