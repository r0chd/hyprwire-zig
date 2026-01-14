const std = @import("std");
const mem = std.mem;

const MessageType = @import("../MessageType.zig").MessageType;
const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;
const Message = @import("root.zig");

pub const vtable: Message.VTable = .{
    .getFds = getFds,
    .getData = getData,
    .getLen = getLen,
    .getMessageType = getMessageType,
};

pub fn getFds(ptr: *anyopaque) []const i32 {
    _ = ptr;
    return &.{};
}

pub fn getData(ptr: *anyopaque) []const u8 {
    const self: *const Self = @ptrCast(@alignCast(ptr));
    return self.data;
}

pub fn getLen(ptr: *anyopaque) usize {
    const self: *const Self = @ptrCast(@alignCast(ptr));
    return self.len;
}

pub fn getMessageType(ptr: *anyopaque) MessageType {
    const self: *const Self = @ptrCast(@alignCast(ptr));
    return self.message_type;
}

seq: u32 = 0,
data: []const u8,
len: usize,
message_type: MessageType = .roundtrip_request,

const Self = @This();

pub fn init(seq: u32) Self {
    var data_array = [_]u8{
        @intFromEnum(MessageType.roundtrip_request),
        @intFromEnum(MessageMagic.type_uint),
        0,
        0,
        0,
        0,
        @intFromEnum(MessageMagic.end),
    };

    mem.writeInt(u32, data_array[2..6], seq, .little);

    return .{
        .seq = seq,
        .data = &data_array,
        .len = data_array.len,
        .message_type = .roundtrip_request,
    };
}

pub fn fromBytes(data: []const u8, offset: usize) !Self {
    if (offset + 7 > data.len) return error.OutOfRange;

    if (data[offset] != @intFromEnum(MessageType.roundtrip_request)) return error.InvalidMessage;

    if (data[offset + 1] != @intFromEnum(MessageMagic.type_uint)) return error.InvalidMessage;

    const seq = mem.readInt(u32, data[offset + 2 .. offset + 6][0..4], .little);

    if (data[offset + 6] != @intFromEnum(MessageMagic.end)) return error.InvalidMessage;

    return .{
        .seq = seq,
        .data = data[offset..][0..7],
        .len = 7,
        .message_type = .roundtrip_request,
    };
}

pub fn message(self: *Self) Message {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

test "RoundtripRequest" {
    const ServerClient = @import("../../server/ServerClient.zig");
    const posix = std.posix;

    const alloc = std.testing.allocator;

    {
        var msg = Self.init(42);

        const pipes = try posix.pipe();
        defer {
            posix.close(pipes[0]);
            posix.close(pipes[1]);
        }
        const server_client = try ServerClient.init(pipes[0]);
        server_client.sendMessage(alloc, msg.message());
    }
    {
        // Message format: [type][UINT_magic][seq:4][END]
        // seq = 42 (0x2A 0x00 0x00 0x00)
        const bytes = [_]u8{
            @intFromEnum(MessageType.roundtrip_request),
            @intFromEnum(MessageMagic.type_uint),
            0x2A,                           0x00, 0x00, 0x00, // seq = 42
            @intFromEnum(MessageMagic.end),
        };
        var msg = try Self.fromBytes(&bytes, 0);

        const pipes = try posix.pipe();
        defer {
            posix.close(pipes[0]);
            posix.close(pipes[1]);
        }
        const server_client = try ServerClient.init(pipes[0]);
        server_client.sendMessage(alloc, msg.message());
    }
}
