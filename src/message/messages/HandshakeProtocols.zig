const std = @import("std");
const mem = std.mem;

const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;
const message_parser = @import("../MessageParser.zig");
const MessageType = @import("../MessageType.zig").MessageType;
const Message = @import("Message.zig");
const Error = Message.Error;

protocols: []const []const u8,
interface: Message,

const Self = @This();

pub fn init(gpa: mem.Allocator, protocols: []const []const u8) mem.Allocator.Error!Self {
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(gpa);

    try data.append(gpa, @intFromEnum(MessageType.handshake_protocols));
    try data.append(gpa, @intFromEnum(MessageMagic.type_array));
    try data.append(gpa, @intFromEnum(MessageMagic.type_varchar));

    var arr_len_buf: [10]u8 = undefined;
    try data.appendSlice(gpa, message_parser.encodeVarInt(protocols.len, &arr_len_buf));

    for (protocols) |protocol| {
        var str_len_buf: [10]u8 = undefined;
        try data.appendSlice(gpa, message_parser.encodeVarInt(protocol.len, &str_len_buf));
        try data.appendSlice(gpa, protocol);
    }

    try data.append(gpa, @intFromEnum(MessageMagic.end));

    const data_slice = try data.toOwnedSlice(gpa);

    var protocols_owned = try gpa.alloc([]const u8, protocols.len);
    errdefer gpa.free(protocols_owned);

    errdefer {
        for (protocols_owned) |p| {
            if (p.len > 0) gpa.free(p);
        }
    }

    for (protocols, 0..) |p, i| {
        protocols_owned[i] = try gpa.dupe(u8, p);
    }

    return .{
        .protocols = protocols_owned,
        .interface = .{
            .data = data_slice,
            .len = data_slice.len,
            .message_type = .handshake_protocols,
        },
    };
}

pub fn fromBytes(gpa: mem.Allocator, data: []const u8, offset: usize) (mem.Allocator.Error || Error)!Self {
    if (offset >= data.len) return Error.UnexpectedEof;

    if (data[offset + 0] != @intFromEnum(MessageType.handshake_protocols)) return Error.InvalidMessageType;
    if (data[offset + 1] != @intFromEnum(MessageMagic.type_array)) return Error.InvalidFieldType;
    if (data[offset + 2] != @intFromEnum(MessageMagic.type_varchar)) return Error.InvalidFieldType;

    var needle: usize = 3;

    const res = message_parser.parseVarInt(data, offset + needle);
    needle += res.@"1";

    const count = res.@"0";

    var protocols_list: std.ArrayList([]const u8) = try .initCapacity(gpa, count);
    errdefer {
        for (protocols_list.items) |p| {
            gpa.free(p);
        }
        protocols_list.deinit(gpa);
    }

    for (0..count) |_| {
        if (offset + needle >= data.len) return Error.UnexpectedEof;

        const r = message_parser.parseVarInt(data, offset + needle);

        if (offset + needle + r.@"1" + r.@"0" > data.len) return Error.UnexpectedEof;

        const protocol_slice = data[offset + needle + r.@"1" .. offset + needle + r.@"1" + r.@"0"];
        const owned_protocol = try gpa.dupe(u8, protocol_slice);
        protocols_list.appendAssumeCapacity(owned_protocol);

        needle += r.@"0" + r.@"1";
    }

    if (data[offset + needle] != @intFromEnum(MessageMagic.end)) return Error.MalformedMessage;

    const len = needle + 1;

    const owned_data = try gpa.dupe(u8, data[offset .. offset + len]);
    errdefer gpa.free(owned_data);

    const protocols_owned = try protocols_list.toOwnedSlice(gpa);

    return .{
        .protocols = protocols_owned,
        .interface = .{
            .data = owned_data,
            .len = len,
            .message_type = .handshake_protocols,
        },
    };
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    gpa.free(self.interface.data);
    for (self.protocols) |p| {
        gpa.free(p);
    }
    gpa.free(self.protocols);
}

test "HandshakeProtocols.init" {
    const alloc = std.testing.allocator;

    var msg = try Self.init(alloc, &.{ "test@1", "test@2" });
    defer msg.deinit(alloc);

    const data = try msg.interface.parseData(alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("handshake_protocols ( { \"test@1\", \"test@2\" } ) ", data);
    try std.testing.expectEqualSlices(i32, msg.interface.getFds(), &.{});
    try std.testing.expectEqual(msg.interface.len, 19);
}

test "HandshakeProtocols.fromBytes" {
    const alloc = std.testing.allocator;

    // Message format: [type][ARRAY_magic][VARCHAR_magic][varint_arr_len][varint_str_len][str]...[END]
    // Array length = 1 (0x01)
    // String: "test@12" (7 bytes, varint = 0x07)
    const bytes = [_]u8{
        @intFromEnum(MessageType.handshake_protocols),
        @intFromEnum(MessageMagic.type_array),
        @intFromEnum(MessageMagic.type_varchar),
        0x02, // array length = 2
        0x06, // string length = 6
        't', 'e', 's', 't', '@', '1', // "test@1"
        0x06, // string length = 6
        't',                            'e', 's', 't', '@', '2', // "test@2"
        @intFromEnum(MessageMagic.end),
    };

    var msg = try Self.fromBytes(alloc, &bytes, 0);
    defer msg.deinit(alloc);

    const data = try msg.interface.parseData(alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("handshake_protocols ( { \"test@1\", \"test@2\" } ) ", data);
}

test "HandshakeProtocols errors" {
    const alloc = std.testing.allocator;

    // Message format: [type][ARRAY_magic][VARCHAR_magic][varint_arr_len][varint_str_len][str]...[END]
    // Array length = 1 (0x01)
    // String: "test@12" (7 bytes, varint = 0x07)
    const bytes = [_]u8{
        @intFromEnum(MessageType.handshake_protocols),
        @intFromEnum(MessageMagic.type_array),
        @intFromEnum(MessageMagic.type_varchar),
        0x02, // array length = 2
        0x06, // string length = 6
        't', 'e', 's', 't', '@', '1', // "test@1"
        0x06, // string length = 6
        't', 'e', 's', 't', '@', '2', // "test@2"
        1,
    };

    const msg = Self.fromBytes(alloc, &bytes, 0);
    try std.testing.expectError(@as(anyerror, Error.MalformedMessage), msg);
}
