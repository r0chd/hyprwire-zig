const std = @import("std");
const helpers = @import("helpers");

const mem = std.mem;
const trait = helpers.trait;

const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;
const MessageType = @import("../MessageType.zig").MessageType;

pub const BindProtocol = @import("BindProtocol.zig");
pub const FatalProtocolError = @import("FatalProtocolError.zig");
pub const GenericProtocolMessage = @import("GenericProtocolMessage.zig");
pub const HandshakeAck = @import("HandshakeAck.zig");
pub const HandshakeBegin = @import("HandshakeBegin.zig");
pub const HandshakeProtocols = @import("HandshakeProtocols.zig");
pub const Hello = @import("Hello.zig");
pub const RoundtripDone = @import("RoundtripDone.zig");
pub const RoundtripRequest = @import("RoundtripRequest.zig");
pub const NewObject = @import("NewObject.zig");

pub const Message = trait.Trait(.{
    .getFds = fn () []const i32,
    .getData = fn () []const u8,
    .getLen = fn () usize,
    .getMessageType = fn () MessageType,
}, null);

pub fn parseData(message: Message, gpa: mem.Allocator) ![]const u8 {
    var result = std.ArrayList(u8).initCapacity(gpa, 64) catch return error.OutOfMemory;
    defer result.deinit(gpa);
    try result.writer(gpa).print("{s} ( ", .{@tagName(message.vtable.getMessageType(message.ptr))});

    var needle: usize = 1;
    const message_data = message.vtable.getData(message.ptr);
    while (needle < message_data.len) {
        const magic_byte = message_data[needle];

        switch (try std.meta.intToEnum(MessageMagic, magic_byte)) {
            .end => {
                break;
            },
            .type_seq => {
                if (needle + 5 > message.vtable.getLen(message.ptr)) break;
                const value = std.mem.readInt(u32, message_data[needle + 1 .. needle + 5][0..4], .little);
                try result.writer(gpa).print("seq: {}", .{value});
                needle += 5;
                continue;
            },
            .type_uint => {
                if (needle + 5 > message.vtable.getLen(message.ptr)) break;
                const value = std.mem.readInt(u32, message_data[needle + 1 .. needle + 5][0..4], .little);
                try result.writer(gpa).print("{}", .{value});
                needle += 5;
                continue;
            },
            .type_int => {
                if (needle + 5 > message.vtable.getLen(message.ptr)) break;
                const value = std.mem.readInt(i32, message_data[needle + 1 .. needle + 5][0..4], .little);
                try result.writer(gpa).print("{}", .{value});
                needle += 5;
                continue;
            },
            .type_f32 => {
                if (needle + 5 > message.vtable.getLen(message.ptr)) break;
                const int_value = std.mem.readInt(u32, message_data[needle + 1 .. needle + 5][0..4], .little);
                const value: f32 = @bitCast(int_value);
                try result.writer(gpa).print("{}", .{value});
                needle += 5;
                continue;
            },
            .type_object_id => {
                if (needle + 5 > message.vtable.getLen(message.ptr)) break;
                const value = std.mem.readInt(u32, message_data[needle + 1 .. needle + 5][0..4], .little);
                try result.writer(gpa).print("object_id({})", .{value});
                needle += 5;
                continue;
            },
            .type_varchar => {
                needle += 1;
                var str_len: usize = 0;
                var shift: u6 = 0;
                while (needle < message.vtable.getLen(message.ptr)) {
                    const byte = message_data[needle];
                    str_len |= @as(usize, byte & 0x7F) << shift;
                    needle += 1;
                    if ((byte & 0x80) == 0) break;
                    shift += 7;
                    if (shift >= 64) break;
                }
                if (needle + str_len > message.vtable.getLen(message.ptr)) break;
                needle += str_len;
                continue;
            },
            .type_array => {
                needle += 1;
                if (needle >= message.vtable.getLen(message.ptr)) break;
                const arr_type_byte = message_data[needle];
                const arr_type: ?MessageMagic = blk: {
                    if (arr_type_byte == @intFromEnum(MessageMagic.type_uint)) break :blk MessageMagic.type_uint;
                    if (arr_type_byte == @intFromEnum(MessageMagic.type_int)) break :blk MessageMagic.type_int;
                    if (arr_type_byte == @intFromEnum(MessageMagic.type_f32)) break :blk MessageMagic.type_f32;
                    if (arr_type_byte == @intFromEnum(MessageMagic.type_object_id)) break :blk MessageMagic.type_object_id;
                    if (arr_type_byte == @intFromEnum(MessageMagic.type_seq)) break :blk MessageMagic.type_seq;
                    if (arr_type_byte == @intFromEnum(MessageMagic.type_varchar)) break :blk MessageMagic.type_varchar;
                    if (arr_type_byte == @intFromEnum(MessageMagic.type_fd)) break :blk MessageMagic.type_fd;
                    break :blk null;
                };
                needle += 1;

                var arr_len: usize = 0;
                var arr_shift: u6 = 0;
                while (needle < message.vtable.getLen(message.ptr)) {
                    const byte = message_data[needle];
                    arr_len |= @as(usize, byte & 0x7F) << arr_shift;
                    needle += 1;
                    if ((byte & 0x80) == 0) break;
                    arr_shift += 7;
                    if (arr_shift >= 64) break;
                }

                if (arr_type) |at| {
                    switch (at) {
                        .type_uint, .type_int, .type_f32, .type_object_id, .type_seq => {
                            if (needle + (arr_len * 4) > message.vtable.getLen(message.ptr)) break;
                            needle += arr_len * 4;
                        },
                        .type_varchar => {
                            for (0..arr_len) |_| {
                                var str_len2: usize = 0;
                                var str_shift: u6 = 0;
                                while (needle < message.vtable.getLen(message.ptr)) {
                                    const byte = message_data[needle];
                                    str_len2 |= @as(usize, byte & 0x7F) << str_shift;
                                    needle += 1;
                                    if ((byte & 0x80) == 0) break;
                                    str_shift += 7;
                                    if (str_shift >= 64) break;
                                }
                                if (needle + str_len2 > message.vtable.getLen(message.ptr)) break;
                                needle += str_len2;
                            }
                        },
                        .type_fd => {},
                        else => break,
                    }
                }
                continue;
            },
            .type_object => {
                needle += 1;
                if (needle + 4 > message.vtable.getLen(message.ptr)) break;
                _ = std.mem.readInt(u32, message_data[needle..][0..4], .little);
                needle += 4;

                var name_len: usize = 0;
                var name_shift: u6 = 0;
                while (needle < message.vtable.getLen(message.ptr)) {
                    const byte = message_data[needle];
                    name_len |= @as(usize, byte & 0x7F) << name_shift;
                    needle += 1;
                    if ((byte & 0x80) == 0) break;
                    name_shift += 7;
                    if (name_shift >= 64) break;
                }
                if (needle + name_len > message.vtable.getLen(message.ptr)) break;
                needle += name_len;
                continue;
            },
            .type_fd => {
                needle += 1;
                continue;
            },
        }
    }
    try result.append(gpa, ')');
    return result.toOwnedSlice(gpa);
}

test {
    std.testing.refAllDecls(@This());
}
