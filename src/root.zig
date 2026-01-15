const std = @import("std");

const time = std.time;

pub const types = @import("implementation/types.zig");
pub const messages = @import("message/messages/root.zig");

pub const ServerSocket = @import("server/ServerSocket.zig");
pub const ClientSocket = @import("client/ClientSocket.zig");

pub const MessageMagic = @import("types/MessageMagic.zig").MessageMagic;
pub const Scanner = @import("scanner.zig");

const ServerObject = @import("server/ServerObject.zig");
const ClientObject = @import("client/ClientObject.zig");

var start: ?time.Instant = null;

pub fn steadyMillis() u64 {
    const now = time.Instant.now() catch return 0;
    if (start) |s| {
        return now.since(s);
    } else {
        start = now;
        return 0;
    }
}

test {
    _ = ServerObject;
    _ = ClientObject;
    _ = messages.BindProtocol;
    _ = messages.FatalProtocolError;
    _ = messages.GenericProtocolMessage;
    _ = messages.HandshakeAck;
    _ = messages.HandshakeBegin;
    _ = messages.HandshakeProtocols;
    _ = messages.Hello;
    _ = messages.RoundtripDone;
    _ = messages.RoundtripRequest;
}

test "fromFd" {
    const SocketRawParsedMessage = @import("./socket/socket_helpers.zig").SocketRawParsedMessage;
    const alloc = std.testing.allocator;

    var msg = try SocketRawParsedMessage.fromFd(alloc, 1);
    defer msg.deinit(alloc);
}
