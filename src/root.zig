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

test "BindProtocol" {
    const BindProtocol = @import("message/messages/BindProtocol.zig");
    const ServerClient = @import("server/ServerClient.zig");
    const MessageType = @import("message/MessageType.zig").MessageType;
    const MessageMagic = @import("types/MessageMagic.zig").MessageMagic;

    const alloc = std.testing.allocator;

    {
        const message = try BindProtocol.init(alloc, "test@1", 5, 1);
        defer alloc.free(message.base.data);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
    {
        // Message format: [type][UINT_magic][seq:4][VARCHAR_magic][varint_len][protocol][UINT_magic][version:4][END]
        // protocol = "test@1" (6 bytes), varint encoding of 6 = 0x06
        // seq = 5 (0x05 0x00 0x00 0x00)
        // version = 1 (0x01 0x00 0x00 0x00)
        const bytes = [_]u8{
            @intFromEnum(MessageType.bind_protocol),
            @intFromEnum(MessageMagic.type_uint),
            0x05, 0x00, 0x00, 0x00, // seq = 5
            @intFromEnum(MessageMagic.type_varchar),
            0x06, // varint length = 6
            't', 'e', 's', 't', '@', '1', // protocol = "test@1"
            @intFromEnum(MessageMagic.type_uint),
            0x01, 0x00, 0x00, 0x00, // version = 1
            @intFromEnum(MessageMagic.end),
        };
        const message = try BindProtocol.fromBytes(&bytes, 0);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
}

test "HandshakeAck" {
    const HandshakeAck = @import("message/messages/HandshakeAck.zig");
    const ServerClient = @import("server/ServerClient.zig");
    const MessageType = @import("message/MessageType.zig").MessageType;
    const MessageMagic = @import("types/MessageMagic.zig").MessageMagic;

    const alloc = std.testing.allocator;

    {
        const message = HandshakeAck.init(1);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
    {
        // Message format: [type][UINT_magic][version:4][END]
        // version = 1 (0x01 0x00 0x00 0x00)
        const bytes = [_]u8{
            @intFromEnum(MessageType.handshake_ack),
            @intFromEnum(MessageMagic.type_uint),
            0x01, 0x00, 0x00, 0x00, // version = 1
            @intFromEnum(MessageMagic.end),
        };
        const message = try HandshakeAck.fromBytes(&bytes, 0);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
}

test "RoundtripRequest" {
    const RoundtripRequest = @import("message/messages/RoundtripRequest.zig");
    const ServerClient = @import("server/ServerClient.zig");
    const MessageType = @import("message/MessageType.zig").MessageType;
    const MessageMagic = @import("types/MessageMagic.zig").MessageMagic;

    const alloc = std.testing.allocator;

    {
        const message = RoundtripRequest.init(42);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
    {
        // Message format: [type][UINT_magic][seq:4][END]
        // seq = 42 (0x2A 0x00 0x00 0x00)
        const bytes = [_]u8{
            @intFromEnum(MessageType.roundtrip_request),
            @intFromEnum(MessageMagic.type_uint),
            0x2A, 0x00, 0x00, 0x00, // seq = 42
            @intFromEnum(MessageMagic.end),
        };
        const message = try RoundtripRequest.fromBytes(&bytes, 0);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
}

test "RoundtripDone" {
    const RoundtripDone = @import("message/messages/RoundtripDone.zig");
    const ServerClient = @import("server/ServerClient.zig");
    const MessageType = @import("message/MessageType.zig").MessageType;
    const MessageMagic = @import("types/MessageMagic.zig").MessageMagic;

    const alloc = std.testing.allocator;

    {
        const message = RoundtripDone.init(42);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
    {
        // Message format: [type][UINT_magic][seq:4][END]
        // seq = 42 (0x2A 0x00 0x00 0x00)
        const bytes = [_]u8{
            @intFromEnum(MessageType.roundtrip_done),
            @intFromEnum(MessageMagic.type_uint),
            0x2A, 0x00, 0x00, 0x00, // seq = 42
            @intFromEnum(MessageMagic.end),
        };
        const message = try RoundtripDone.fromBytes(&bytes, 0);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
}
