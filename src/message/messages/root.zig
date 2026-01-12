const std = @import("std");

const mem = std.mem;

const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;
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

pub fn Message(comptime T: type) void {
    if (@typeInfo(T) != .@"struct")
        @compileError("type " ++ @typeName(T) ++ " is not a struct");

    const required_methods = [_][]const u8{"fds"};

    inline for (required_methods) |method_name| {
        if (!@hasDecl(T, method_name))
            @compileError("type '" ++ @typeName(T) ++ "' has no method '" ++ method_name ++ "'");
    }

    const required_fields = [_]struct {
        name: [:0]const u8,
        type: type,
    }{
        .{
            .name = "data",
            .type = []const u8,
        },
        .{
            .name = "message_type",
            .type = MessageType,
        },
        .{
            .name = "len",
            .type = usize,
        },
    };

    inline for (required_fields) |field| {
        if (!@hasField(T, field.name))
            @compileError("type " ++ @typeName(T) ++ " has no field '" ++ field.name ++ "'");
        if (@FieldType(T, field.name) != field.type)
            @compileError("field '" ++ field.name ++ "' on type '" ++ @typeName(T) ++ "' has mismatched type, expected: '" ++ @typeName(field.type) ++ "' got '" ++ @typeName(@FieldType(T, field.name)) ++ "'");
    }
}

pub fn parseData(gpa: mem.Allocator, message: anytype) ![]const u8 {
    comptime Message(@TypeOf(message));

    var result = std.ArrayList(u8).initCapacity(gpa, 64) catch return error.OutOfMemory;
    defer result.deinit(gpa);
    try result.writer(gpa).print("{s} ( ", .{@tagName(message.message_type)});

    var needle: usize = 1;
    while (needle < message.data.len) {
        switch (@as(MessageMagic, @enumFromInt(message.data[needle]))) {
            .end => {
                break;
            },
            .type_seq => {
                const value = std.mem.readInt(u32, message.data[needle + 1 .. needle + 5][0..4], .little);
                try result.writer(gpa).print("seq: {}", .{value});
                needle += 5;
                break;
            },
            .type_uint => {
                const value = std.mem.readInt(u32, message.data[needle + 1 .. needle + 5][0..4], .little);
                try result.writer(gpa).print("{}", .{value});
                needle += 5;
                break;
            },
            .type_int => {
                const value = std.mem.readInt(i32, message.data[needle + 1 .. needle + 5][0..4], .little);
                try result.writer(gpa).print("{}", .{value});
                needle += 5;
                break;
            },
            .type_f32 => {
                const int_value = std.mem.readInt(u32, message.data[needle + 1 .. needle + 5][0..4], .little);
                const value: f32 = @bitCast(int_value);
                try result.writer(gpa).print("{}", .{value});
                needle += 5;
                break;
            },
            .type_varchar => {
                break;
            },
            .type_array => {
                break;
            },
            .type_object => {
                break;
            },
            .type_fd => {
                break;
            },
            else => {
                needle += 1;
            },
        }
    }
    try result.append(gpa, ')');
    return result.toOwnedSlice(gpa);
}
