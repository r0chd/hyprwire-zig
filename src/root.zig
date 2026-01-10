const std = @import("std");

const time = std.time;

var start: ?time.Instant = null;

pub fn steadyMillis() u64 {
    const now = time.Instant.now() catch unreachable;
    if (start) |s| {
        return now.since(s);
    } else {
        start = now;
        return 0;
    }
}

test "fromFd" {
    const SocketRawParsedMessage = @import("./socket/socket_helpers.zig").SocketRawParsedMessage;
    const alloc = std.testing.allocator;
    const debug = std.debug;

    var msg = try SocketRawParsedMessage.fromFd(alloc, 1);
    defer msg.deinit(alloc);

    debug.assert(!msg.bad);
}

test "Hello" {
    const Hello = @import("message/messages/Hello.zig");
    const ServerClient = @import("server/ServerClient.zig");
    const MessageType = @import("message/MessageType.zig").MessageType;
    const MessageMagic = @import("types/MessageMagic.zig").MessageMagic;

    const alloc = std.testing.allocator;

    {
        const message = Hello.init();

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
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
        const message = try Hello.fromBytes(&bytes, 0);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
}

test "NewObject" {
    const NewObject = @import("message/messages/NewObject.zig");
    const ServerClient = @import("server/ServerClient.zig");
    const MessageType = @import("message/MessageType.zig").MessageType;
    const MessageMagic = @import("types/MessageMagic.zig").MessageMagic;

    const alloc = std.testing.allocator;

    {
        const message = NewObject.init(3, 2);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
    {
        const bytes = [_]u8{
            @intFromEnum(MessageType.new_object),
            @intFromEnum(MessageMagic.type_uint),
            0x03,                                 0x00, 0x00, 0x00, // id = 3
            @intFromEnum(MessageMagic.type_uint),
            0x02,                           0x00, 0x00, 0x00, // seq = 2
            @intFromEnum(MessageMagic.end),
        };
        const message = try NewObject.fromBytes(&bytes, 0);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
}
