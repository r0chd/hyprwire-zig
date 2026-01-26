const std = @import("std");
const mem = std.mem;

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
    if (offset >= data.len) return Error.UnexpectedEof;
    if (data[offset] != @intFromEnum(MessageType.generic_protocol_message)) return Error.InvalidMessageType;

    var needle = offset + 1;

    if (needle >= data.len) return Error.UnexpectedEof;
    if (data[needle] != @intFromEnum(MessageMagic.type_object)) return Error.InvalidFieldType;
    needle += 1;
    if (needle + 4 > data.len) return Error.UnexpectedEof;
    const object_id = mem.readInt(u32, data[needle..][0..4], .little);
    needle += 4;

    if (needle >= data.len) return Error.UnexpectedEof;
    if (data[needle] != @intFromEnum(MessageMagic.type_uint)) return Error.InvalidFieldType;
    needle += 1;
    if (needle + 4 > data.len) return Error.UnexpectedEof;
    const method_id = mem.readInt(u32, data[needle..][0..4], .little);
    needle += 4;

    var fds_consumed: std.ArrayList(i32) = .empty;
    errdefer fds_consumed.deinit(gpa);

    var data_needle = needle;
    while (data_needle < data.len) {
        if (data[data_needle] == @intFromEnum(MessageMagic.end)) break;

        const magic: MessageMagic = @enumFromInt(data[data_needle]);
        data_needle += 1;

        switch (magic) {
            .type_uint, .type_int, .type_f32, .type_object, .type_seq => {
                data_needle += 4;
            },
            .type_varchar => {
                var str_len: usize = 0;
                var shift: u6 = 0;
                while (data_needle < data.len) {
                    const byte = data[data_needle];
                    str_len |= @as(usize, byte & 0x7F) << shift;
                    data_needle += 1;
                    if ((byte & 0x80) == 0) break;
                    shift += 7;
                    if (shift >= 64) return Error.MalformedMessage;
                }
                if (data_needle + str_len > data.len) return Error.UnexpectedEof;
                data_needle += str_len;
            },
            .type_array => {
                if (data_needle >= data.len) return Error.UnexpectedEof;
                const arr_type: MessageMagic = @enumFromInt(data[data_needle]);
                data_needle += 1;

                var arr_len: usize = 0;
                var arr_shift: u6 = 0;
                while (data_needle < data.len) {
                    const byte = data[data_needle];
                    arr_len |= @as(usize, byte & 0x7F) << arr_shift;
                    data_needle += 1;
                    if ((byte & 0x80) == 0) break;
                    arr_shift += 7;
                    if (arr_shift >= 64) return Error.MalformedMessage;
                }

                switch (arr_type) {
                    .type_uint, .type_int, .type_f32, .type_object, .type_seq => {
                        data_needle += arr_len * 4;
                    },
                    .type_varchar => {
                        for (0..arr_len) |_| {
                            var str_len2: usize = 0;
                            var str_shift: u6 = 0;
                            while (data_needle < data.len) {
                                const byte = data[data_needle];
                                str_len2 |= @as(usize, byte & 0x7F) << str_shift;
                                data_needle += 1;
                                if ((byte & 0x80) == 0) break;
                                str_shift += 7;
                                if (str_shift >= 64) return Error.MalformedMessage;
                            }
                            if (data_needle + str_len2 > data.len) return Error.UnexpectedEof;
                            data_needle += str_len2;
                        }
                    },
                    .type_fd => {
                        if (fds_list.items.len == 0) return Error.MalformedMessage;
                        try fds_consumed.append(gpa, fds_list.items[0]);
                        _ = fds_list.orderedRemove(0);
                    },
                    else => return Error.InvalidFieldType,
                }
            },
            .type_fd => {
                if (fds_list.items.len == 0) return Error.MalformedMessage;
                try fds_consumed.append(gpa, fds_list.items[0]);
                _ = fds_list.orderedRemove(0);
            },
            else => {
                return Error.InvalidFieldType;
            },
        }
    }

    if (data_needle >= data.len or data[data_needle] != @intFromEnum(MessageMagic.end)) return Error.MalformedMessage;
    data_needle += 1;

    const message_len = data_needle - offset;

    const data_copy = try gpa.dupe(u8, data[offset .. offset + message_len]);

    return .{
        .object = object_id,
        .method = method_id,
        .data_span = data_copy[11..],
        .fds_list = try fds_consumed.toOwnedSlice(gpa),
        .data = data_copy,
        .len = message_len,
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

test "GenericProtocolMessage.fromBytes" {
    const messages = @import("./root.zig");
    const alloc = std.testing.allocator;

    // Message format: [type][OBJECT_magic][object:4][UINT_magic][method:4][...data...][END]
    // object = 1 (0x01 0x00 0x00 0x00)
    // method = 2 (0x02 0x00 0x00 0x00)
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
