const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const enums = std.enums;

const MessageMagic = @import("hyprwire").MessageMagic;
const Trait = @import("trait").Trait;

const message_parser = @import("../MessageParser.zig");
const MessageType = @import("../MessageType.zig").MessageType;
pub const BindProtocol = @import("BindProtocol.zig");
pub const FatalProtocolError = @import("FatalProtocolError.zig");
pub const GenericProtocolMessage = @import("GenericProtocolMessage.zig");
pub const HandshakeAck = @import("HandshakeAck.zig");
pub const HandshakeBegin = @import("HandshakeBegin.zig");
pub const HandshakeProtocols = @import("HandshakeProtocols.zig");
pub const Hello = @import("Hello.zig");
pub const NewObject = @import("NewObject.zig");
pub const RoundtripDone = @import("RoundtripDone.zig");
pub const RoundtripRequest = @import("RoundtripRequest.zig");

pub const Error = error{
    UnexpectedEof,
    InvalidMessageType,
    InvalidFieldType,
    InvalidVarInt,
    InvalidProtocolLength,
    InvalidVersion,
    MalformedMessage,
};

data: []const u8,
len: usize,
message_type: MessageType = .invalid,
fdsFn: *const fn (ptr: *const Self) []const i32 = defaultGetFds,

const Self = @This();

pub fn getFds(self: *const Self) []const i32 {
    return self.fdsFn(self);
}

fn defaultGetFds(ptr: *const Self) []const i32 {
    _ = ptr;
    return &.{};
}

pub fn parseData(self: Self, gpa: mem.Allocator) (std.Io.Writer.Error || mem.Allocator.Error || Error)![]const u8 {
    var result: std.Io.Writer.Allocating = .init(gpa);
    defer result.deinit();

    try result.writer.print("{s} ( ", .{@tagName(self.message_type)});

    var first: bool = true;
    var needle: usize = 1;
    while (needle < self.data.len) {
        const magic_byte = self.data[needle];
        needle += 1;

        const magic = enums.fromInt(MessageMagic, magic_byte) orelse return Error.MalformedMessage;
        switch (magic) {
            .end => {
                break;
            },
            .type_seq => {
                if (!first) _ = try result.writer.write(", ");
                first = false;
                const value = mem.readVarInt(u32, self.data[needle .. needle + 4], .little);
                try result.writer.print("seq: {}", .{value});
                needle += 4;
            },
            .type_uint => {
                if (!first) _ = try result.writer.write(", ");
                first = false;
                const value = mem.readVarInt(u32, self.data[needle .. needle + 4], .little);
                try result.writer.print("{}", .{value});
                needle += 4;
            },
            .type_int => {
                if (!first) _ = try result.writer.write(", ");
                first = false;
                const value = mem.readVarInt(i32, self.data[needle .. needle + 4], .little);
                try result.writer.print("{}", .{value});
                needle += 4;
            },
            .type_f32 => {
                if (!first) _ = try result.writer.write(", ");
                first = false;
                const int_bits = mem.readVarInt(u32, self.data[needle .. needle + 4], .little);
                const value: f32 = @bitCast(int_bits);
                try result.writer.print("{}", .{value});
                needle += 4;
            },
            .type_varchar => {
                if (!first) _ = try result.writer.write(", ");
                first = false;
                const len, const int_len = message_parser.parseVarInt(self.data, needle);
                if (len > 0) {
                    const ptr = self.data[needle + int_len .. needle + int_len + len];
                    try result.writer.print("\"{s}\"", .{ptr[0..len]});
                } else {
                    _ = try result.writer.write("\"\"");
                }
                needle += int_len + len;
            },
            .type_array => {
                if (!first) _ = try result.writer.write(", ");
                first = false;
                const this_type = enums.fromInt(MessageMagic, self.data[needle]) orelse return Error.MalformedMessage;
                needle += 1;
                const els, const int_len = message_parser.parseVarInt(self.data, needle);
                _ = try result.writer.write("{ ");
                needle += int_len;

                for (0..els) |i| {
                    const str, const len = try formatPrimitiveType(gpa, self.data[needle..], this_type);
                    defer gpa.free(str);

                    needle += len;
                    try result.writer.print("{s}", .{str});
                    if (i < els - 1) {
                        try result.writer.print(", ", .{});
                    }
                }

                _ = try result.writer.write(" }");
            },
            .type_object => {
                if (!first) _ = try result.writer.write(", ");
                first = false;
                const id = mem.readVarInt(u32, self.data[needle .. needle + 4], .little);
                needle += 4;
                try result.writer.print("object({})", .{id});
            },
            .type_fd => {
                if (!first) _ = try result.writer.write(", ");
                first = false;
                _ = try result.writer.write("<fd>");
            },
            else => return Error.MalformedMessage,
        }
    }

    try result.writer.writeAll(" ) ");
    return result.toOwnedSlice();
}

fn formatPrimitiveType(
    gpa: mem.Allocator,
    s: []const u8,
    @"type": MessageMagic,
) mem.Allocator.Error!std.meta.Tuple(&.{ [:0]const u8, usize }) {
    switch (@"type") {
        .type_uint => {
            const value = mem.readVarInt(u32, s[0..4], .little);
            return .{ try fmt.allocPrintSentinel(gpa, "{}", .{value}, 0), 4 };
        },
        .type_int => {
            const value = mem.readVarInt(i32, s[0..4], .little);
            return .{ try fmt.allocPrintSentinel(gpa, "{}", .{value}, 0), 4 };
        },
        .type_f32 => {
            const int_bits = mem.readVarInt(u32, s[0..4], .little);
            const value: f32 = @bitCast(int_bits);
            return .{ try fmt.allocPrintSentinel(gpa, "{}", .{value}, 0), 4 };
        },
        .type_fd => {
            return .{ try gpa.dupeZ(u8, "<fd>"), 0 };
        },
        .type_object => {
            const id = mem.readVarInt(u32, s[0..4], .little);
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

test {
    std.testing.refAllDecls(@This());
}

test "parseData integer types" {
    const alloc = std.testing.allocator;

    const bytes_data = [_]u8{
        @intFromEnum(MessageType.generic_protocol_message),
        @intFromEnum(MessageMagic.type_seq),
        0x01,                                0x00, 0x00, 0x00, // object = 1
        @intFromEnum(MessageMagic.type_int),
        0x01,                                0x00, 0x00, 0x00, // object = 1
        @intFromEnum(MessageMagic.type_f32),
        0x01,                           0x00, 0x00, 0x00, // object = 1
        @intFromEnum(MessageMagic.end),
    };
    var message = try GenericProtocolMessage.init(alloc, &bytes_data, &.{});
    defer message.deinit(alloc);
    const data = try message.interface.parseData(alloc);
    defer alloc.free(data);
}

test "parseData varchar" {
    const alloc = std.testing.allocator;

    const bytes_data = [_]u8{
        @intFromEnum(MessageType.generic_protocol_message),
        @intFromEnum(MessageMagic.type_varchar),
        @intFromEnum(MessageMagic.end),
    };
    var message = try GenericProtocolMessage.init(alloc, &bytes_data, &.{});
    defer message.deinit(alloc);
    const data = try message.interface.parseData(alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("generic_protocol_message ( \"\" ) ", data);
}
