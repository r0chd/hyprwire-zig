const std = @import("std");
const mem = std.mem;

const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;
const MessageType = @import("../MessageType.zig").MessageType;
const Message = @import("Message.zig");
const Error = Message.Error;

object_id: u32 = 0,
error_id: u32 = 0,
error_msg: []const u8,
interface: Message,

const Self = @This();

pub fn initBuffer(buffer: []u8, object_id: u32, error_id: u32, error_msg: []const u8) Self {
    var varint_len: usize = 1;
    var msg_len = error_msg.len;
    while (msg_len > 0x7F) {
        varint_len += 1;
        msg_len >>= 7;
    }

    // message_type(1) + magic_type_uint(1) + object_id(4) +  magic_type_uint(1) + error_id(4) +
    // magic_type_varchar(1) + varint_len(error_msg) + error_msg_len + magic_end(1)
    const estimated_capacity = 1 + 1 + 4 + 1 + 4 + 1 + varint_len + error_msg.len + 1;

    var data = std.ArrayList(u8).initBuffer(buffer);

    data.appendAssumeCapacity(@intFromEnum(MessageType.fatal_protocol_error));
    data.appendAssumeCapacity(@intFromEnum(MessageMagic.type_uint));
    var object_id_buf: [4]u8 = undefined;
    mem.writeInt(u32, &object_id_buf, object_id, .little);
    data.appendSliceAssumeCapacity(&object_id_buf);

    data.appendAssumeCapacity(@intFromEnum(MessageMagic.type_uint));
    var error_id_buf: [4]u8 = undefined;
    mem.writeInt(u32, &error_id_buf, error_id, .little);
    data.appendSliceAssumeCapacity(&error_id_buf);

    data.appendAssumeCapacity(@intFromEnum(MessageMagic.type_varchar));
    while (msg_len > 0x7F) {
        data.appendAssumeCapacity(@as(u8, @truncate(msg_len & 0x7F)) | 0x80);
        msg_len >>= 7;
    }
    data.appendAssumeCapacity(@as(u8, @truncate(msg_len)));
    data.appendSliceAssumeCapacity(error_msg);

    data.appendAssumeCapacity(@intFromEnum(MessageMagic.end));

    return .{
        .object_id = object_id,
        .error_id = error_id,
        .error_msg = error_msg,
        .interface = .{
            .len = estimated_capacity,
            .data = data.items[0..data.items.len],
            .message_type = .fatal_protocol_error,
        },
    };
}

pub fn init(gpa: mem.Allocator, object_id: u32, error_id: u32, error_msg: []const u8) mem.Allocator.Error!Self {
    var varint_len: usize = 1;
    var msg_len = error_msg.len;
    while (msg_len > 0x7F) {
        varint_len += 1;
        msg_len >>= 7;
    }

    // message_type(1) + magic_type_uint(1) + object_id(4) +  magic_type_uint(1) + error_id(4) +
    // magic_type_varchar(1) + varint_len(error_msg) + error_msg_len + magic_end(1)
    const estimated_capacity = 1 + 1 + 4 + 1 + 4 + 1 + varint_len + error_msg.len + 1;

    var data = try std.ArrayList(u8).initCapacity(gpa, estimated_capacity);
    errdefer data.deinit(gpa);

    data.appendAssumeCapacity(@intFromEnum(MessageType.fatal_protocol_error));
    data.appendAssumeCapacity(@intFromEnum(MessageMagic.type_uint));
    var object_id_buf: [4]u8 = undefined;
    mem.writeInt(u32, &object_id_buf, object_id, .little);
    data.appendSliceAssumeCapacity(&object_id_buf);

    data.appendAssumeCapacity(@intFromEnum(MessageMagic.type_uint));
    var error_id_buf: [4]u8 = undefined;
    mem.writeInt(u32, &error_id_buf, error_id, .little);
    data.appendSliceAssumeCapacity(&error_id_buf);

    data.appendAssumeCapacity(@intFromEnum(MessageMagic.type_varchar));
    while (msg_len > 0x7F) {
        data.appendAssumeCapacity(@as(u8, @truncate(msg_len & 0x7F)) | 0x80);
        msg_len >>= 7;
    }
    data.appendAssumeCapacity(@as(u8, @truncate(msg_len)));
    data.appendSliceAssumeCapacity(error_msg);

    data.appendAssumeCapacity(@intFromEnum(MessageMagic.end));

    return .{
        .object_id = object_id,
        .error_id = error_id,
        .error_msg = error_msg,
        .interface = .{
            .len = data.items.len,
            .data = try data.toOwnedSlice(gpa),
            .message_type = .fatal_protocol_error,
        },
    };
}

pub fn fromBytes(gpa: mem.Allocator, data: []const u8, offset: usize) (mem.Allocator.Error || Error)!Self {
    if (offset >= data.len) return Error.UnexpectedEof;
    if (data[offset] != @intFromEnum(MessageType.fatal_protocol_error)) return Error.InvalidMessageType;

    var needle = offset + 1;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.type_uint)) return Error.InvalidFieldType;
    needle += 1;
    if (needle + 4 > data.len) return Error.UnexpectedEof;
    const object_id = mem.readInt(u32, data[needle..][0..4], .little);
    needle += 4;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.type_uint)) return Error.InvalidFieldType;
    needle += 1;
    if (needle + 4 > data.len) return Error.UnexpectedEof;
    const error_id = mem.readInt(u32, data[needle..][0..4], .little);
    needle += 4;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.type_varchar)) return Error.InvalidFieldType;
    needle += 1;

    var msg_len: usize = 0;
    var shift: u6 = 0;
    while (needle < data.len) {
        const byte = data[needle];
        msg_len |= @as(usize, byte & 0x7F) << shift;
        needle += 1;
        if ((byte & 0x80) == 0) break;
        shift += 7;
        if (shift >= 64) return Error.InvalidVarInt;
    }

    if (needle + msg_len > data.len) return Error.UnexpectedEof;
    const error_msg = data[needle..][0..msg_len];
    needle += msg_len;

    if (needle >= data.len or data[needle] != @intFromEnum(MessageMagic.end)) return Error.MalformedMessage;
    needle += 1;

    return Self{
        .interface = .{
            .data = try gpa.dupe(u8, data[offset..needle]),
            .len = needle - offset,
            .message_type = .fatal_protocol_error,
        },
        .object_id = object_id,
        .error_id = error_id,
        .error_msg = error_msg,
    };
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    gpa.free(self.interface.data);
}

test "FatalProtocolError.init" {
    const alloc = std.testing.allocator;

    var msg = try Self.init(alloc, 3, 5, "test error");
    defer msg.deinit(alloc);

    const data = try msg.interface.parseData(alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("fatal_protocol_error ( 3, 5, \"test error\" ) ", data);
}

test "FatalProtocolError.fromBytes" {
    const alloc = std.testing.allocator;

    // Message format: [type][UINT_magic][objectId:4][UINT_magic][errorId:4][VARCHAR_magic][varint_len][errorMsg][END]
    // objectId = 3 (0x03 0x00 0x00 0x00)
    // errorId = 5 (0x05 0x00 0x00 0x00)
    // errorMsg = "test error" (10 bytes, varint = 0x0A)
    const bytes = [_]u8{
        @intFromEnum(MessageType.fatal_protocol_error),
        @intFromEnum(MessageMagic.type_uint),
        0x03,                                 0x00, 0x00, 0x00, // objectId = 3
        @intFromEnum(MessageMagic.type_uint),
        0x05,                                    0x00, 0x00, 0x00, // errorId = 5
        @intFromEnum(MessageMagic.type_varchar),
        0x0A, // errorMsg length = 10
        't',                            'e', 's', 't', ' ', 'e', 'r', 'r', 'o', 'r', // "test error"
        @intFromEnum(MessageMagic.end),
    };
    var msg = try Self.fromBytes(alloc, &bytes, 0);
    defer msg.deinit(alloc);

    const data = try msg.interface.parseData(alloc);
    defer alloc.free(data);

    try std.testing.expectEqualStrings("fatal_protocol_error ( 3, 5, \"test error\" ) ", data);
}
