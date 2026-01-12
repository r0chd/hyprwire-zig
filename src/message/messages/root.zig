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
        const magic_byte = message.data[needle];
        
        // Safely convert to enum - check if value is valid
        const magic: ?MessageMagic = blk: {
            // Check if the byte value is a valid enum value
            if (magic_byte == @intFromEnum(MessageMagic.end)) break :blk MessageMagic.end;
            if (magic_byte == @intFromEnum(MessageMagic.type_uint)) break :blk MessageMagic.type_uint;
            if (magic_byte == @intFromEnum(MessageMagic.type_int)) break :blk MessageMagic.type_int;
            if (magic_byte == @intFromEnum(MessageMagic.type_f32)) break :blk MessageMagic.type_f32;
            if (magic_byte == @intFromEnum(MessageMagic.type_seq)) break :blk MessageMagic.type_seq;
            if (magic_byte == @intFromEnum(MessageMagic.type_object_id)) break :blk MessageMagic.type_object_id;
            if (magic_byte == @intFromEnum(MessageMagic.type_varchar)) break :blk MessageMagic.type_varchar;
            if (magic_byte == @intFromEnum(MessageMagic.type_array)) break :blk MessageMagic.type_array;
            if (magic_byte == @intFromEnum(MessageMagic.type_object)) break :blk MessageMagic.type_object;
            if (magic_byte == @intFromEnum(MessageMagic.type_fd)) break :blk MessageMagic.type_fd;
            break :blk null;
        };
        
        if (magic) |m| {
            switch (m) {
                .end => {
                    break;
                },
                .type_seq => {
                    if (needle + 5 > message.data.len) break;
                    const value = std.mem.readInt(u32, message.data[needle + 1 .. needle + 5][0..4], .little);
                    try result.writer(gpa).print("seq: {}", .{value});
                    needle += 5;
                    continue;
                },
                .type_uint => {
                    if (needle + 5 > message.data.len) break;
                    const value = std.mem.readInt(u32, message.data[needle + 1 .. needle + 5][0..4], .little);
                    try result.writer(gpa).print("{}", .{value});
                    needle += 5;
                    continue;
                },
                .type_int => {
                    if (needle + 5 > message.data.len) break;
                    const value = std.mem.readInt(i32, message.data[needle + 1 .. needle + 5][0..4], .little);
                    try result.writer(gpa).print("{}", .{value});
                    needle += 5;
                    continue;
                },
                .type_f32 => {
                    if (needle + 5 > message.data.len) break;
                    const int_value = std.mem.readInt(u32, message.data[needle + 1 .. needle + 5][0..4], .little);
                    const value: f32 = @bitCast(int_value);
                    try result.writer(gpa).print("{}", .{value});
                    needle += 5;
                    continue;
                },
                .type_object_id => {
                    if (needle + 5 > message.data.len) break;
                    const value = std.mem.readInt(u32, message.data[needle + 1 .. needle + 5][0..4], .little);
                    try result.writer(gpa).print("object_id({})", .{value});
                    needle += 5;
                    continue;
                },
                .type_varchar => {
                    needle += 1; // Skip magic byte
                    // Parse varint length
                    var str_len: usize = 0;
                    var shift: u6 = 0;
                    while (needle < message.data.len) {
                        const byte = message.data[needle];
                        str_len |= @as(usize, byte & 0x7F) << shift;
                        needle += 1;
                        if ((byte & 0x80) == 0) break;
                        shift += 7;
                        if (shift >= 64) break;
                    }
                    if (needle + str_len > message.data.len) break;
                    // For formatting, we could print the string, but for now just skip it
                    needle += str_len;
                    continue;
                },
                .type_array => {
                    needle += 1; // Skip magic byte
                    if (needle >= message.data.len) break;
                    const arr_type_byte = message.data[needle];
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
                    
                    // Parse varint array length
                    var arr_len: usize = 0;
                    var arr_shift: u6 = 0;
                    while (needle < message.data.len) {
                        const byte = message.data[needle];
                        arr_len |= @as(usize, byte & 0x7F) << arr_shift;
                        needle += 1;
                        if ((byte & 0x80) == 0) break;
                        arr_shift += 7;
                        if (arr_shift >= 64) break;
                    }
                    
                    // Skip array elements based on type
                    if (arr_type) |at| {
                        switch (at) {
                            .type_uint, .type_int, .type_f32, .type_object_id, .type_seq => {
                                if (needle + (arr_len * 4) > message.data.len) break;
                                needle += arr_len * 4;
                            },
                            .type_varchar => {
                                for (0..arr_len) |_| {
                                    var str_len2: usize = 0;
                                    var str_shift: u6 = 0;
                                    while (needle < message.data.len) {
                                        const byte = message.data[needle];
                                        str_len2 |= @as(usize, byte & 0x7F) << str_shift;
                                        needle += 1;
                                        if ((byte & 0x80) == 0) break;
                                        str_shift += 7;
                                        if (str_shift >= 64) break;
                                    }
                                    if (needle + str_len2 > message.data.len) break;
                                    needle += str_len2;
                                }
                            },
                            .type_fd => {
                                // FDs are passed via control, not in data
                            },
                            else => break,
                        }
                    }
                    continue;
                },
                .type_object => {
                    needle += 1; // Skip magic byte
                    if (needle + 4 > message.data.len) break;
                    _ = std.mem.readInt(u32, message.data[needle..][0..4], .little); // object_id, not used in formatting
                    needle += 4;
                    
                    // Parse varint name length
                    var name_len: usize = 0;
                    var name_shift: u6 = 0;
                    while (needle < message.data.len) {
                        const byte = message.data[needle];
                        name_len |= @as(usize, byte & 0x7F) << name_shift;
                        needle += 1;
                        if ((byte & 0x80) == 0) break;
                        name_shift += 7;
                        if (name_shift >= 64) break;
                    }
                    if (needle + name_len > message.data.len) break;
                    needle += name_len;
                    continue;
                },
                .type_fd => {
                    // FD is passed via control, not in data, just skip the magic byte
                    needle += 1;
                    continue;
                },
            }
        } else {
            // Not a valid enum value, skip it
            needle += 1;
        }
    }
    try result.append(gpa, ')');
    return result.toOwnedSlice(gpa);
}
