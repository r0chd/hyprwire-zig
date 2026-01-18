const std = @import("std");
const helpers = @import("helpers");
const message_parser = @import("../MessageParser.zig");

const mem = std.mem;
const trait = helpers.trait;
const fmt = std.fmt;
const meta = std.meta;

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

fn formatPrimitiveType(gpa: mem.Allocator, s: []const u8, @"type": MessageMagic) !std.meta.Tuple(&.{ [:0]const u8, usize }) {
    switch (@"type") {
        .type_uint => {
            const value = std.mem.readVarInt(u32, s[0..4], .little);
            return .{ try fmt.allocPrintSentinel(gpa, "{}", .{value}, 0), 4 };
        },
        .type_int => {
            const value = std.mem.readVarInt(i32, s[0..4], .little);
            return .{ try fmt.allocPrintSentinel(gpa, "{}", .{value}, 0), 4 };
        },
        .type_f32 => {
            const int_bits = std.mem.readVarInt(u32, s[0..4], .little);
            const value = @as(f32, @bitCast(int_bits));
            return .{ try fmt.allocPrintSentinel(gpa, "{}", .{value}, 0), 4 };
        },
        .type_fd => {
            return .{ try gpa.dupeZ(u8, "<fd>"), 0 };
        },
        .type_object => {
            const id = std.mem.readVarInt(u32, s[0..4], .little);
            const obj_str = if (id == 0) "null" else try fmt.allocPrintSentinel(gpa, "{}", .{id}, 0);
            return .{ try fmt.allocPrintSentinel(gpa, "object: {s}", .{obj_str}, 0), 4 };
        },
        .type_varchar => {
            const len, const int_len = message_parser.parseVarInt(s, 0);
            const ptr = s[int_len .. int_len + len];
            const formatted = try fmt.allocPrintSentinel(gpa, "\"{s}\"", .{ptr}, 0);
            return .{ formatted, len + int_len };
        },
        else => return .{ try gpa.dupeZ(u8, ""), 0 },
    }
}

pub fn parseData(message: Message, gpa: mem.Allocator) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(gpa);

    var writer = result.writer(gpa);
    try writer.print("{s} ( ", .{messageTypeToStr(message.vtable.getMessageType(message.ptr))});

    var needle: usize = 1;
    const message_data = message.vtable.getData(message.ptr);
    while (needle < message_data.len) {
        const magic_byte = message_data[needle];
        needle += 1;

        const magic = meta.intToEnum(MessageMagic, magic_byte) catch return error.InvalidMessage;
        switch (magic) {
            .end => {
                break;
            },
            .type_seq => {
                const value = std.mem.readVarInt(u32, message_data[needle .. needle + 4], .little);
                try writer.print("seq: {}", .{value});
                needle += 4;
            },
            .type_uint => {
                const value = std.mem.readVarInt(u32, message_data[needle .. needle + 4], .little);
                try writer.print("{}", .{value});
                needle += 4;
            },
            .type_int => {
                const value = std.mem.readVarInt(i32, message_data[needle .. needle + 4], .little);
                try writer.print("{}", .{value});
                needle += 4;
            },
            .type_f32 => {
                const int_bits = std.mem.readVarInt(u32, message_data[needle .. needle + 4], .little);
                const value = @as(f32, @bitCast(int_bits));
                try writer.print("{}", .{value});
                needle += 4;
            },
            .type_varchar => {
                const len, const int_len = message_parser.parseVarInt(message_data, needle);
                if (len > 0) {
                    const ptr = message_data[needle + int_len .. needle + int_len + len];
                    try writer.print("\"{s}\"", .{ptr[0..len]});
                } else {
                    _ = try writer.write("\"\"");
                }
                needle += int_len + len;
            },
            .type_array => {
                const this_type = meta.intToEnum(MessageMagic, message_data[needle]) catch return error.InvalidMessage;
                needle += 1;
                const els, const int_len = message_parser.parseVarInt(message_data, needle);
                _ = try writer.write("{ ");
                needle += int_len;

                for (0..els) |i| {
                    const str, const len = try formatPrimitiveType(gpa, message_data[needle..], this_type);
                    defer gpa.free(str);

                    needle += len;
                    try writer.print("{s}", .{str});
                    if (i < els - 1) {
                        try writer.print(", ", .{});
                    }
                }

                _ = try writer.write(" }");
            },
            .type_object => {
                const id = std.mem.readVarInt(u32, message_data[needle .. needle + 4], .little);
                needle += 4;
                try writer.print("object({})", .{id});
            },
            .type_fd => {
                _ = try writer.write("<fd>");
            },
            else => return error.InvalidMessage,
        }

        _ = try writer.write(", ");
    }

    if (result.items.len >= 2 and result.items[result.items.len - 2] == ',') {
        _ = result.pop();
        _ = result.pop();
    }
    if (result.items.len >= 2 and result.items[result.items.len - 2] == ',') {
        _ = result.pop();
        _ = result.pop();
    }

    try result.appendSlice(gpa, " ) ");
    return result.toOwnedSlice(gpa);
}

fn messageTypeToStr(t: MessageType) []const u8 {
    return switch (t) {
        .invalid => "invalid",
        .sup => "sup",
        .handshake_begin => "handshake_begin",
        .handshake_ack => "handshake_ack",
        .handshake_protocols => "handshake_protocols",
        .bind_protocol => "bind_protocol",
        .new_object => "new_object",
        .fatal_protocol_error => "fatal_protocol_error",
        .generic_protocol_message => "generic_protocol_message",
        .roundtrip_request => "roundtrip_request",
        .roundtrip_done => "roundtrip_done",
    };
}

test {
    std.testing.refAllDecls(@This());
}
