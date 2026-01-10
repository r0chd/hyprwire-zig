const std = @import("std");

const time = std.time;

const ServerClient = @import("server/ServerClient.zig");
const SocketRawParsedMessage = @import("./socket/socket_helpers.zig").SocketRawParsedMessage;
const Hello = @import("message/messages/Hello.zig");

var start: ?time.Instant = null;

pub fn steadyMillis() u64 {
    const now = time.Instant.now() catch unreachable;
    if (start) |s| {
        return s.since(now);
    } else {
        start = now;
        return 0;
    }
}

test "fromFd" {
    const alloc = std.testing.allocator;
    const debug = std.debug;

    var msg = try SocketRawParsedMessage.fromFd(alloc, 1);
    defer msg.deinit(alloc);

    debug.assert(!msg.bad);
}

test "server" {
    const message = Hello.init();

    const server_client = try ServerClient.init(0);
    server_client.sendMessage(std.testing.allocator, message);
}
