const std = @import("std");

const time = std.time;
const posix = std.posix;
const mem = std.mem;

const ServerSocket = @import("server/ServerSocket.zig");

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

pub fn sunLen(addr: *const posix.sockaddr.un) usize {
    const path_ptr: [*:0]const u8 = @ptrCast(&addr.path);
    const path_len = mem.span(path_ptr).len;
    return @offsetOf(posix.sockaddr.un, "path") + path_len + 1;
}

test "ServerSocket" {
    const alloc = std.testing.allocator;
    var socket = (try ServerSocket.open(alloc, null)).?;
    defer socket.deinit(alloc);
}

test "fromFd" {
    const SocketRawParsedMessage = @import("./socket/socket_helpers.zig").SocketRawParsedMessage;
    const alloc = std.testing.allocator;

    var msg = try SocketRawParsedMessage.fromFd(alloc, 1);
    defer msg.deinit(alloc);
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
        var message = try BindProtocol.init(alloc, "test@1", 5, 1);
        defer message.deinit(alloc);

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
            0x05,                                    0x00, 0x00, 0x00, // seq = 5
            @intFromEnum(MessageMagic.type_varchar),
            0x06, // varint length = 6
            't',                                  'e', 's', 't', '@', '1', // protocol = "test@1"
            @intFromEnum(MessageMagic.type_uint),
            0x01,                           0x00, 0x00, 0x00, // version = 1
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
            0x01,                           0x00, 0x00, 0x00, // version = 1
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
            0x2A,                           0x00, 0x00, 0x00, // seq = 42
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
            0x2A,                           0x00, 0x00, 0x00, // seq = 42
            @intFromEnum(MessageMagic.end),
        };
        const message = try RoundtripDone.fromBytes(&bytes, 0);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
}

test "HandshakeProtocols" {
    const HandshakeProtocols = @import("message/messages/HandshakeProtocols.zig");
    const ServerClient = @import("server/ServerClient.zig");
    const MessageType = @import("message/MessageType.zig").MessageType;
    const MessageMagic = @import("types/MessageMagic.zig").MessageMagic;

    const alloc = std.testing.allocator;

    {
        const protocols = [_][]const u8{ "test@1", "test2@2" };
        var message = try HandshakeProtocols.init(alloc, &protocols);
        defer message.deinit(alloc);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
    {
        // Message format: [type][ARRAY_magic][VARCHAR_magic][varint_arr_len][varint_str_len][str]...[END]
        // Array length = 2 (0x02)
        // First string: "test@1" (6 bytes, varint = 0x06)
        // Second string: "test2@2" (7 bytes, varint = 0x07)
        const bytes = [_]u8{
            @intFromEnum(MessageType.handshake_protocols),
            @intFromEnum(MessageMagic.type_array),
            @intFromEnum(MessageMagic.type_varchar),
            0x02, // array length = 2
            0x06, // first string length = 6
            't', 'e', 's', 't', '@', '1', // "test@1"
            0x07, // second string length = 7
            't',                            'e', 's', 't', '2', '@', '2', // "test2@2"
            @intFromEnum(MessageMagic.end),
        };
        var message = try HandshakeProtocols.fromBytes(alloc, &bytes, 0);
        defer message.deinit(alloc);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
}

test "HandshakeBegin" {
    const HandshakeBegin = @import("message/messages/HandshakeBegin.zig");
    const ServerClient = @import("server/ServerClient.zig");
    const MessageType = @import("message/MessageType.zig").MessageType;
    const MessageMagic = @import("types/MessageMagic.zig").MessageMagic;

    const alloc = std.testing.allocator;

    {
        const versions = [_]u32{ 1, 2 };
        var message = try HandshakeBegin.init(alloc, &versions);
        defer message.deinit(alloc);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
    {
        // Message format: [type][ARRAY_magic][UINT_magic][varint_arr_len][version1:4][version2:4]...[END]
        // Array length = 2 (0x02)
        // version1 = 1 (0x01 0x00 0x00 0x00)
        // version2 = 2 (0x02 0x00 0x00 0x00)
        const bytes = [_]u8{
            @intFromEnum(MessageType.handshake_begin),
            @intFromEnum(MessageMagic.type_array),
            @intFromEnum(MessageMagic.type_uint),
            0x02, // array length = 2
            0x01, 0x00, 0x00, 0x00, // version = 1
            0x02,                           0x00, 0x00, 0x00, // version = 2
            @intFromEnum(MessageMagic.end),
        };
        var message = try HandshakeBegin.fromBytes(alloc, &bytes, 0);
        defer message.deinit(alloc);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
}

test "FatalProtocolError" {
    const FatalProtocolError = @import("message/messages/FatalProtocolError.zig");
    const ServerClient = @import("server/ServerClient.zig");
    const MessageType = @import("message/MessageType.zig").MessageType;
    const MessageMagic = @import("types/MessageMagic.zig").MessageMagic;

    const alloc = std.testing.allocator;

    {
        var message = try FatalProtocolError.init(alloc, 3, 5, "test error");
        defer message.deinit(alloc);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
    {
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
        var message = try FatalProtocolError.fromBytes(alloc, &bytes, 0);
        defer message.deinit(alloc);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
}

test "GenericProtocolMessage" {
    const GenericProtocolMessage = @import("message/messages/GenericProtocolMessage.zig");
    const ServerClient = @import("server/ServerClient.zig");
    const MessageType = @import("message/MessageType.zig").MessageType;
    const MessageMagic = @import("types/MessageMagic.zig").MessageMagic;

    const alloc = std.testing.allocator;

    {
        const data = [_]u8{
            @intFromEnum(MessageType.generic_protocol_message),
            @intFromEnum(MessageMagic.type_object),
            0x01,                                 0x00, 0x00, 0x00, // object = 1
            @intFromEnum(MessageMagic.type_uint),
            0x02,                           0x00, 0x00, 0x00, // method = 2
            @intFromEnum(MessageMagic.end),
        };
        var message = try GenericProtocolMessage.init(alloc, &data, &.{});
        defer message.deinit(alloc);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
    {
        // Message format: [type][OBJECT_magic][object:4][UINT_magic][method:4][...data...][END]
        // object = 1 (0x01 0x00 0x00 0x00)
        // method = 2 (0x02 0x00 0x00 0x00)
        const bytes = [_]u8{
            @intFromEnum(MessageType.generic_protocol_message),
            @intFromEnum(MessageMagic.type_object),
            0x01,                                 0x00, 0x00, 0x00, // object = 1
            @intFromEnum(MessageMagic.type_uint),
            0x02,                           0x00, 0x00, 0x00, // method = 2
            @intFromEnum(MessageMagic.end),
        };
        var fds_list: std.ArrayList(i32) = .empty;
        defer fds_list.deinit(alloc);
        var message = try GenericProtocolMessage.fromBytes(alloc, &bytes, &fds_list, 0);
        defer message.deinit(alloc);

        const server_client = try ServerClient.init(0);
        server_client.sendMessage(alloc, message);
    }
}
