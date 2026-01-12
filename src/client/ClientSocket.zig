const std = @import("std");
const types = @import("../implementation/types.zig");
const message = @import("../message/messages/root.zig");

const mem = std.mem;
const posix = std.posix;
const log = std.log;

const ClientObject = @import("ClientObject.zig");

const Message = message.Message;
const ProtocolClientImplementation = types.ProtocolClientImplementation;
const ProtocolSpec = types.ProtocolSpec;

const parseData = message.parseData;
const steadyMillis = @import("../root.zig").steadyMillis;

fd: i32,
impls: std.ArrayList(*const ProtocolClientImplementation) = .empty,
server_specs: std.ArrayList(*const ProtocolSpec) = .empty,
pollfds: std.ArrayList(posix.pollfd) = .empty,
objects: std.ArrayList(ClientObject) = .empty,
@"error": bool = false,

const Self = @This();

pub fn sendMessage(self: *Self, gpa: mem.Allocator, msg: anytype) void {
    comptime Message(msg);

    const parsed = parseData(gpa, msg) catch |err| {
        log.debug("[{} @ {}] -> parse error: {}", .{ self.fd, steadyMillis(), err });
        return;
    };
    defer gpa.free(parsed);
    log.debug("[{} @ {}] -> {s}", .{ self.fd, steadyMillis(), parsed });
}
