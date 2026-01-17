const std = @import("std");
const mem = std.mem;

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

protocols: [][]const u8,
data: []const u8,
len: usize,
message_type: MessageType = .handshake_protocols,

const Self = @This();

pub fn init(gpa: mem.Allocator, protocol_list: []const []const u8) !Self {
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(gpa);

    try data.append(gpa, @intFromEnum(MessageType.handshake_protocols));
    try data.append(gpa, @intFromEnum(MessageMagic.type_array));
    try data.append(gpa, @intFromEnum(MessageMagic.type_varchar));

    var arr_len = protocol_list.len;
    while (arr_len > 0x7F) {
        try data.append(gpa, @as(u8, @truncate(arr_len & 0x7F)) | 0x80);
        arr_len >>= 7;
    }
    try data.append(gpa, @as(u8, @truncate(arr_len)));

    for (protocol_list) |protocol| {
        var protocol_len = protocol.len;
        while (protocol_len > 0x7F) {
            try data.append(gpa, @as(u8, @truncate(protocol_len & 0x7F)) | 0x80);
            protocol_len >>= 7;
        }
        try data.append(gpa, @as(u8, @truncate(protocol_len)));
        try data.appendSlice(gpa, protocol);
    }

    try data.append(gpa, @intFromEnum(MessageMagic.end));

    const data_slice = try data.toOwnedSlice(gpa);

    const protocols_slice = try gpa.alloc([]const u8, protocol_list.len);
    errdefer gpa.free(protocols_slice);

    for (protocol_list, 0..) |protocol, i| {
        const protocol_copy = try gpa.dupe(u8, protocol);
        errdefer {
            for (protocols_slice[0..i]) |p| {
                gpa.free(p);
            }
            gpa.free(protocols_slice);
        }
        protocols_slice[i] = protocol_copy;
    }

    return .{
        .protocols = protocols_slice,
        .data = data_slice,
        .len = data_slice.len,
        .message_type = .handshake_protocols,
    };
}

pub fn fromBytes(gpa: mem.Allocator, data: []const u8, offset: usize) !Self {
    if (offset >= data.len) return error.OutOfRange;
    if (data[offset] != @intFromEnum(MessageType.handshake_protocols)) return error.InvalidMessage;

    var needle = offset + 1;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.type_array)) return error.InvalidMessage;
    needle += 1;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.type_varchar)) return error.InvalidMessage;
    needle += 1;

    var arr_len: usize = 0;
    var shift: u6 = 0;
    while (needle < data.len) {
        const byte = data[needle];
        arr_len |= @as(usize, byte & 0x7F) << shift;
        needle += 1;
        if ((byte & 0x80) == 0) break;
        shift += 7;
        if (shift >= 64) return error.InvalidMessage;
    }

    const protocols_slice = try gpa.alloc([]const u8, arr_len);
    errdefer {
        for (protocols_slice) |protocol| {
            gpa.free(protocol);
        }
        gpa.free(protocols_slice);
    }

    for (0..arr_len) |i| {
        var str_len: usize = 0;
        shift = 0;
        while (needle < data.len) {
            const byte = data[needle];
            str_len |= @as(usize, byte & 0x7F) << shift;
            needle += 1;
            if ((byte & 0x80) == 0) break;
            shift += 7;
            if (shift >= 64) return error.InvalidMessage;
        }

        if (needle + str_len > data.len) return error.OutOfRange;
        const protocol_str = try gpa.dupe(u8, data[needle..][0..str_len]);
        errdefer {
            for (protocols_slice[0..i]) |p| {
                gpa.free(p);
            }
            gpa.free(protocols_slice);
        }
        protocols_slice[i] = protocol_str;
        needle += str_len;
    }

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.end)) return error.InvalidMessage;
    needle += 1;

    const message_len = needle - offset;

    return .{
        .protocols = protocols_slice,
        .data = try gpa.dupe(u8, data[offset..][0..message_len]),
        .len = message_len,
        .message_type = .handshake_protocols,
    };
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    gpa.free(self.data);
    for (self.protocols) |protocol| {
        gpa.free(protocol);
    }
    gpa.free(self.protocols);
}

test "HandshakeProtocols.init" {
    const messages = @import("./root.zig");
    const alloc = std.testing.allocator;

    const protocols = [_][]const u8{ "test@1", "test2@2" };
    var msg = try Self.init(alloc, &protocols);
    defer msg.deinit(alloc);

    const data = try messages.parseData(Message.from(&msg), alloc);
    defer alloc.free(data);

    std.debug.print("HandshakeProtocols: {s}\n", .{data});
}

test "HandshakeProtocols.fromBytes" {
    const messages = @import("./root.zig");
    const alloc = std.testing.allocator;

    // Message format: [type][ARRAY_magic][VARCHAR_magic][varint_arr_len][varint_str_len][str]...[END]
    // Array length = 2 (0x02)
    // First string: "test@1" (6 bytes, varint = 0x06)
    // Second string: "test2@2" (7 bytes, varint = 0x07)
    const bytes = [_]u8{
        @intFromEnum(MessageType.handshake_protocols),
        @intFromEnum(MessageMagic.type_array),
        @intFromEnum(MessageMagic.type_varchar),
        0x02, // array length = 2
        0x06, // first string length = 6
        't', 'e', 's', 't', '@', '1', // "test@1"
        0x07, // second string length = 7
        't',                            'e', 's', 't', '2', '@', '2', // "test2@2"
        @intFromEnum(MessageMagic.end),
    };
    var msg = try Self.fromBytes(alloc, &bytes, 0);
    defer msg.deinit(alloc);

    const data = try messages.parseData(Message.from(&msg), alloc);
    defer alloc.free(data);

    std.debug.print("HandshakeProtocols: {s}\n", .{data});
}
