const std = @import("std");
const mem = std.mem;

const Message = @import("Message.zig");
const MessageType = @import("../MessageType.zig").MessageType;
const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;

object: u32 = 0,
method: u32 = 0,
data_span: []const u8,
fds_list: []const i32,
base: Message,

const Self = @This();

pub fn init(gpa: mem.Allocator, data: []const u8, fds_list: []const i32) !Self {
    const data_copy = try gpa.dupe(u8, data);
    const fds_copy = try gpa.dupe(i32, fds_list);

    return Self{
        .base = Message{
            .data = data_copy,
            .len = data_copy.len,
            .message_type = .generic_protocol_message,
        },
        .object = 0,
        .method = 0,
        .data_span = data_copy,
        .fds_list = fds_copy,
    };
}

pub fn fromBytes(gpa: mem.Allocator, data: []const u8, fds_list: *std.ArrayList(i32), offset: usize) !Self {
    if (offset >= data.len) return error.OutOfRange;
    if (data[offset] != @intFromEnum(MessageType.generic_protocol_message)) return error.InvalidMessage;

    var needle = offset + 1;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.type_object)) return error.InvalidMessage;
    needle += 1;
    if (needle + 4 > data.len) return error.OutOfRange;
    const object_id = mem.readInt(u32, data[needle..][0..4], .little);
    needle += 4;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.type_uint)) return error.InvalidMessage;
    needle += 1;
    if (needle + 4 > data.len) return error.OutOfRange;
    const method_id = mem.readInt(u32, data[needle..][0..4], .little);
    needle += 4;

    var fds_consumed: std.ArrayList(i32) = .empty;
    errdefer fds_consumed.deinit(gpa);

    var data_needle = needle;
    while (data_needle < data.len) {
        if (data[data_needle] == @intFromEnum(MessageMagic.end)) break;

        const magic = @as(MessageMagic, @enumFromInt(data[data_needle]));
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
                    if (shift >= 64) return error.InvalidMessage;
                }
                if (data_needle + str_len > data.len) return error.OutOfRange;
                data_needle += str_len;
            },
            .type_array => {
                if (data_needle >= data.len) return error.OutOfRange;
                const arr_type = @as(MessageMagic, @enumFromInt(data[data_needle]));
                data_needle += 1;

                var arr_len: usize = 0;
                var arr_shift: u6 = 0;
                while (data_needle < data.len) {
                    const byte = data[data_needle];
                    arr_len |= @as(usize, byte & 0x7F) << arr_shift;
                    data_needle += 1;
                    if ((byte & 0x80) == 0) break;
                    arr_shift += 7;
                    if (arr_shift >= 64) return error.InvalidMessage;
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
                                if (str_shift >= 64) return error.InvalidMessage;
                            }
                            if (data_needle + str_len2 > data.len) return error.OutOfRange;
                            data_needle += str_len2;
                        }
                    },
                    .type_fd => {
                        if (fds_list.items.len == 0) return error.InvalidMessage;
                        try fds_consumed.append(gpa, fds_list.items[0]);
                        _ = fds_list.orderedRemove(0);
                    },
                    else => return error.InvalidMessage,
                }
            },
            .type_fd => {
                if (fds_list.items.len == 0) return error.InvalidMessage;
                try fds_consumed.append(gpa, fds_list.items[0]);
                _ = fds_list.orderedRemove(0);
            },
            else => return error.InvalidMessage,
        }
    }

    if (data_needle >= data.len or data[data_needle] != @intFromEnum(MessageMagic.end)) return error.InvalidMessage;
    data_needle += 1;

    const message_len = data_needle - offset;

    const data_copy = try gpa.dupe(u8, data[offset .. offset + message_len]);
    const fds_copy = try fds_consumed.toOwnedSlice(gpa);

    return Self{
        .base = Message{
            .data = data_copy,
            .len = message_len,
            .message_type = .generic_protocol_message,
        },
        .object = object_id,
        .method = method_id,
        .data_span = data_copy[11..],
        .fds_list = fds_copy,
    };
}

pub fn fds(self: *const Self) []const i32 {
    return self.fds_list;
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    gpa.free(self.fds_list);
    gpa.free(self.base.data);
}
