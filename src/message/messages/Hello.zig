const std = @import("std");

const mem = std.mem;

const MessageType = @import("../MessageType.zig").MessageType;
const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;
const Message = @import("root.zig");

interface: Message,

const Self = @This();

pub fn init() Self {
    const data = &.{
        @intFromEnum(MessageType.sup),
        @intFromEnum(MessageMagic.type_varchar),
        0x03,
        'V',
        'A',
        'X',
        @intFromEnum(MessageMagic.end),
    };

    return .{
        .interface = .{
            .data = data,
            .len = data.len,
            .message_type = .sup,
            .fdsFn = Self.fdsFn,
        },
    };
}

pub fn fromBytes(data: []const u8, offset: usize) !Self {
    if (offset + 7 > data.len) return error.OutOfRange;

    const expected = [_]u8{
        @intFromEnum(MessageType.sup),
        @intFromEnum(MessageMagic.type_varchar),
        0x03,
        'V',
        'A',
        'X',
        @intFromEnum(MessageMagic.end),
    };

    if (!mem.eql(u8, &expected, data[offset .. offset + 7])) return error.InvalidMessage;

    return .{
        .interface = .{
            .data = data,
            .len = expected.len,
            .message_type = .sup,
            .fdsFn = Self.fdsFn,
        },
    };
}

pub fn fdsFn(ptr: *const Message) []const i32 {
    _ = ptr;
    return &.{};
}

test "Hello" {
    const ServerClient = @import("../../server/ServerClient.zig");
    const posix = std.posix;

    const alloc = std.testing.allocator;

    {
        const message = Self.init();

        const pipes = try posix.pipe();
        defer {
            posix.close(pipes[0]);
            posix.close(pipes[1]);
        }
        const server_client = try ServerClient.init(pipes[0]);
        server_client.sendMessage(alloc, &message.interface);
    }
    {
        const bytes = [_]u8{
            @intFromEnum(MessageType.sup),
            @intFromEnum(MessageMagic.type_varchar),
            0x03,
            'V',
            'A',
            'X',
            @intFromEnum(MessageMagic.end),
        };
        const message = try Self.fromBytes(&bytes, 0);

        const pipes = try posix.pipe();
        defer {
            posix.close(pipes[0]);
            posix.close(pipes[1]);
        }
        const server_client = try ServerClient.init(pipes[0]);
        server_client.sendMessage(alloc, &message.interface);
    }
}
