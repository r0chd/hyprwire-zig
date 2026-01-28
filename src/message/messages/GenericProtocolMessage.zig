const std = @import("std");
const mem = std.mem;
const log = std.log;

const helpers = @import("helpers");

const message_parser = @import("../MessageParser.zig");
const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;
const MessageType = @import("../MessageType.zig").MessageType;
const root = @import("root.zig");
const Message = root.Message;
const Error = root.Error;

pub fn getFds(self: *const Self) []const i32 {
    return self.fds_list;
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

object: u32 = 0,
method: u32 = 0,
data_span: []const u8,
fds_list: []const i32,
data: []const u8,
len: usize,
message_type: MessageType = .generic_protocol_message,

const Self = @This();

pub fn init(gpa: mem.Allocator, data: []const u8, fds_list: []const i32) mem.Allocator.Error!Self {
    const data_copy = try gpa.dupe(u8, data);
    const fds_copy = try gpa.dupe(i32, fds_list);

    return .{
        .data_span = data_copy,
        .fds_list = fds_copy,
        .data = data_copy,
        .len = data_copy.len,
        .message_type = .generic_protocol_message,
    };
}

pub fn fromBytes(gpa: mem.Allocator, data: []const u8, fds_list: *std.ArrayList(i32), offset: usize) (mem.Allocator.Error || Error)!Self {
    if (data[offset + 0] != @intFromEnum(MessageType.generic_protocol_message)) return Error.InvalidMessageType;
    if (data[offset + 1] != @intFromEnum(MessageMagic.type_object)) return Error.InvalidFieldType;

    const object_id = mem.readInt(u32, data[offset + 2 ..][0..4], .little);

    if (data[offset + 6] != @intFromEnum(MessageMagic.type_uint)) return Error.InvalidFieldType;

    const method_id = mem.readInt(u32, data[offset + 7 ..][0..4], .little);

    var fds_consumed: std.ArrayList(i32) = .empty;
    errdefer fds_consumed.deinit(gpa);

    var i: usize = 11;
    while (data[offset + i] != @intFromEnum(MessageMagic.end)) {
        const magic: MessageMagic = @enumFromInt(data[offset + i]);
        switch (magic) {
            .type_uint, .type_int, .type_f32, .type_object, .type_seq => {
                i += 5;
            },
            .type_varchar => {
                const a, const b = message_parser.parseVarInt(data[offset + i + 1 ..], 0);
                i += a + b + 1;
            },
            .type_array => {
                const arr_type: MessageMagic = @enumFromInt(data[offset + i + 1]);
                const arr_len, const len_len = message_parser.parseVarInt(
                    data[offset + i + 2 ..],
                    0,
                );
                var arr_message_len = 2 + len_len;

                switch (arr_type) {
                    .type_uint, .type_int, .type_f32, .type_object, .type_seq => {
                        arr_message_len += 4 * arr_len;
                    },
                    .type_varchar => {
                        for (0..arr_len) |_| {
                            const str_len, const str_len_len = message_parser.parseVarInt(
                                data[offset + i + arr_message_len ..],
                                0,
                            );
                            arr_message_len += str_len + str_len_len;
                        }
                    },
                    .type_fd => {
                        for (0..arr_len) |_| {
                            if (fds_list.items.len == 0) return Error.MalformedMessage;
                            try fds_consumed.append(gpa, fds_list.items[0]);
                            _ = fds_list.swapRemove(0);
                        }
                    },
                    else => {
                        if (helpers.isTrace()) {
                            log.debug("GenericProtocolMessage: failed demarshaling array message", .{});
                        }
                        return Error.InvalidFieldType;
                    },
                }

                i += arr_message_len;
            },
            .type_fd => {
                if (fds_list.items.len == 0) {
                    if (helpers.isTrace()) {
                        log.debug("GenericProtocolMessage: failed demarshaling array message", .{});
                    }
                    return Error.MalformedMessage;
                }
                try fds_consumed.append(gpa, fds_list.orderedRemove(0));

                i += 1;
            },
            else => {
                return Error.InvalidFieldType;
            },
        }
    }

    const data_copy = try gpa.dupe(u8, data);

    return .{
        .object = object_id,
        .method = method_id,
        .data_span = data_copy[11..],
        .fds_list = try fds_consumed.toOwnedSlice(gpa),
        .data = data_copy,
        .len = i + 1,
        .message_type = .generic_protocol_message,
    };
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    gpa.free(self.data);
    gpa.free(self.fds_list);
}

test "GenericProtocolMessage.init" {
    const messages = @import("./root.zig");
    const alloc = std.testing.allocator;

    const bytes_data = [_]u8{
        @intFromEnum(MessageType.generic_protocol_message),
        @intFromEnum(MessageMagic.type_object),
        0x01,                                 0x00, 0x00, 0x00, // object = 1
        @intFromEnum(MessageMagic.type_uint),
        0x02,                           0x00, 0x00, 0x00, // method = 2
        @intFromEnum(MessageMagic.end),
    };
    var msg = try Self.init(alloc, &bytes_data, &.{});
    defer msg.deinit(alloc);

    const data = try messages.parseData(Message.from(&msg), alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("generic_protocol_message ( object(1), 2 ) ", data);
}

test "GenericProtocolMessage.fromBytes - basic structure" {
    const messages = @import("./root.zig");
    const alloc = std.testing.allocator;

    const bytes = [_]u8{
        @intFromEnum(MessageType.generic_protocol_message),
        @intFromEnum(MessageMagic.type_object),
        0x01,                                 0x00, 0x00, 0x00, // object = 1
        @intFromEnum(MessageMagic.type_uint),
        0x02,                           0x00, 0x00, 0x00, // method = 2
        @intFromEnum(MessageMagic.end),
    };
    var fds_list: std.ArrayList(i32) = .empty;
    defer fds_list.deinit(alloc);
    var msg = try Self.fromBytes(alloc, &bytes, &fds_list, 0);
    defer msg.deinit(alloc);

    const data = try messages.parseData(Message.from(&msg), alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("generic_protocol_message ( object(1), 2 ) ", data);
}

test "GenericProtocolMessage.fromBytes - varchar field" {
    const messages = @import("./root.zig");
    const alloc = std.testing.allocator;

    const bytes = [_]u8{
        @intFromEnum(MessageType.generic_protocol_message),
        @intFromEnum(MessageMagic.type_object),
        0x01,                                 0x00, 0x00, 0x00, // object = 1
        @intFromEnum(MessageMagic.type_uint),
        0x02,                                    0x00, 0x00, 0x00, // method = 2
        @intFromEnum(MessageMagic.type_varchar),
        0x04, // length = 4
        't',
        'e',
        's',
        't',
        @intFromEnum(MessageMagic.end),
    };
    var fds_list: std.ArrayList(i32) = .empty;
    defer fds_list.deinit(alloc);
    var msg = try Self.fromBytes(alloc, &bytes, &fds_list, 0);
    defer msg.deinit(alloc);

    const data = try messages.parseData(Message.from(&msg), alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("generic_protocol_message ( object(1), 2, \"test\" ) ", data);
}

test "GenericProtocolMessage.fromBytes - uint array" {
    const messages = @import("./root.zig");
    const alloc = std.testing.allocator;

    const bytes = [_]u8{
        @intFromEnum(MessageType.generic_protocol_message),
        @intFromEnum(MessageMagic.type_object),
        0x01,                                 0x00, 0x00, 0x00, // object = 1
        @intFromEnum(MessageMagic.type_uint),
        0x02,                                  0x00,                                 0x00, 0x00, // method = 2
        @intFromEnum(MessageMagic.type_array), @intFromEnum(MessageMagic.type_uint),
        0x02, // array length = 2
        0x01, 0x00, 0x00, 0x00, // 1
        0x02,                           0x00, 0x00, 0x00, // 2
        @intFromEnum(MessageMagic.end),
    };
    var fds_list: std.ArrayList(i32) = .empty;
    defer fds_list.deinit(alloc);
    var msg = try Self.fromBytes(alloc, &bytes, &fds_list, 0);
    defer msg.deinit(alloc);

    const data = try messages.parseData(Message.from(&msg), alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("generic_protocol_message ( object(1), 2, { 1, 2 } ) ", data);
}

test "GenericProtocolMessage.fromBytes - varchar array" {
    const messages = @import("./root.zig");
    const alloc = std.testing.allocator;

    const bytes = [_]u8{
        @intFromEnum(MessageType.generic_protocol_message),
        @intFromEnum(MessageMagic.type_object),
        0x01,                                 0x00, 0x00, 0x00, // object = 1
        @intFromEnum(MessageMagic.type_uint),
        0x02, 0x00, 0x00, 0x00, // method = 2
        @intFromEnum(MessageMagic.type_array), //
        @intFromEnum(MessageMagic.type_varchar),
        0x01, // array length = 1
        0x04, // string length = 4
        't',
        'e',
        's',
        't',
        @intFromEnum(MessageMagic.end),
    };
    var fds_list: std.ArrayList(i32) = .empty;
    defer fds_list.deinit(alloc);
    var msg = try Self.fromBytes(alloc, &bytes, &fds_list, 0);
    defer msg.deinit(alloc);

    const data = try messages.parseData(Message.from(&msg), alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("generic_protocol_message ( object(1), 2, { \"test\" } ) ", data);
}

test "GenericProtocolMessage.fromBytes - fd array" {
    const messages = @import("./root.zig");
    const alloc = std.testing.allocator;

    const bytes = [_]u8{
        @intFromEnum(MessageType.generic_protocol_message),
        @intFromEnum(MessageMagic.type_object),
        0x01,                                 0x00, 0x00, 0x00, // object = 1
        @intFromEnum(MessageMagic.type_uint),
        0x02, 0x00, 0x00, 0x00, // method = 2
        @intFromEnum(MessageMagic.type_array), //
        @intFromEnum(MessageMagic.type_fd),
        0x02, // array length = 2
        @intFromEnum(MessageMagic.end),
    };
    var fds_list: std.ArrayList(i32) = .empty;
    try fds_list.append(alloc, 1);
    try fds_list.append(alloc, 2);
    defer fds_list.deinit(alloc);
    var msg = try Self.fromBytes(alloc, &bytes, &fds_list, 0);
    defer msg.deinit(alloc);

    const data = try messages.parseData(Message.from(&msg), alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("generic_protocol_message ( object(1), 2, { <fd>, <fd> } ) ", data);
    try std.testing.expectEqualSlices(i32, &.{ 1, 2 }, msg.getFds());
}

test "GenericProtocolMessage.fromBytes - standalone fd" {
    const messages = @import("./root.zig");
    const alloc = std.testing.allocator;

    const bytes = [_]u8{
        @intFromEnum(MessageType.generic_protocol_message),
        @intFromEnum(MessageMagic.type_object),
        0x01,                                 0x00, 0x00, 0x00, // object = 1
        @intFromEnum(MessageMagic.type_uint),
        0x02,                               0x00,                           0x00, 0x00, // method = 2
        @intFromEnum(MessageMagic.type_fd), @intFromEnum(MessageMagic.end),
    };
    var fds_list: std.ArrayList(i32) = .empty;
    try fds_list.append(alloc, 1);
    defer fds_list.deinit(alloc);
    var msg = try Self.fromBytes(alloc, &bytes, &fds_list, 0);
    defer msg.deinit(alloc);

    const data = try messages.parseData(Message.from(&msg), alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("generic_protocol_message ( object(1), 2, <fd> ) ", data);
    try std.testing.expectEqualSlices(i32, &.{1}, msg.getFds());
    try std.testing.expectEqual(bytes.len, msg.getLen());
}

// Don't pass any fd's despite advertising fd in message
test "GenericProtocolMessage.fromBytes - Error.MalformedMessage" {
    const alloc = std.testing.allocator;

    const bytes = [_]u8{
        @intFromEnum(MessageType.generic_protocol_message),
        @intFromEnum(MessageMagic.type_object),
        0x01,                                 0x00, 0x00, 0x00, // object = 1
        @intFromEnum(MessageMagic.type_uint),
        0x02, 0x00, 0x00, 0x00, // method = 2
        @intFromEnum(MessageMagic.type_fd), //
        @intFromEnum(MessageMagic.end),
    };
    var fds_list: std.ArrayList(i32) = .empty;
    const msg = Self.fromBytes(alloc, &bytes, &fds_list, 0);
    try std.testing.expectError(Error.MalformedMessage, msg);
}

test "GenericProtocolMessage.fromBytes - Missing MessageMagic.type_object" {
    const alloc = std.testing.allocator;

    const bytes = [_]u8{
        @intFromEnum(MessageType.generic_protocol_message),
        @intFromEnum(MessageMagic.type_uint),
        0x02,                           0x00, 0x00, 0x00, // method = 2
        @intFromEnum(MessageMagic.end),
    };
    var fds_list: std.ArrayList(i32) = .empty;
    const msg = Self.fromBytes(alloc, &bytes, &fds_list, 0);
    try std.testing.expectError(Error.InvalidFieldType, msg);
}

test "GenericProtocolMessage.fromBytes - Missing MessageMagic.type_uint" {
    const alloc = std.testing.allocator;

    const bytes = [_]u8{
        @intFromEnum(MessageType.generic_protocol_message),
        @intFromEnum(MessageMagic.type_object),
        0x01,                           0x00, 0x00, 0x00, // object = 1
        @intFromEnum(MessageMagic.end),
    };
    var fds_list: std.ArrayList(i32) = .empty;
    const msg = Self.fromBytes(alloc, &bytes, &fds_list, 0);
    try std.testing.expectError(Error.InvalidFieldType, msg);
}

test "GenericProtocolMessage.fromBytes - MessageType.generic_protocol_message" {
    const alloc = std.testing.allocator;

    const bytes = [_]u8{
        @intFromEnum(MessageMagic.type_object),
        0x01,                                 0x00, 0x00, 0x00, // object = 1
        @intFromEnum(MessageMagic.type_uint),
        0x02,                           0x00, 0x00, 0x00, // method = 2
        @intFromEnum(MessageMagic.end),
    };
    var fds_list: std.ArrayList(i32) = .empty;
    const msg = Self.fromBytes(alloc, &bytes, &fds_list, 0);
    try std.testing.expectError(Error.InvalidMessageType, msg);
}
