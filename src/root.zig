const std = @import("std");
const SocketRawParsedMessage = @import("./socket/socket_helpers.zig").SocketRawParsedMessage;

test "fromFd" {
    const alloc = std.testing.allocator;
    const debug = std.debug;

    var msg = try SocketRawParsedMessage.fromFd(alloc, 1);
    defer msg.deinit(alloc);

    debug.assert(!msg.bad);
}
