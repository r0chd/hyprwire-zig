const std = @import("std");
const types = @import("../implementation/types.zig");
const Message = @import("../message/messages/root.zig");
const helpers = @import("helpers");

const mem = std.mem;
const posix = std.posix;
const log = std.log;
const fs = std.fs;

const ClientObject = @import("ClientObject.zig");

const ProtocolClientImplementation = types.ProtocolClientImplementation;
const ProtocolSpec = types.ProtocolSpec;

const steadyMillis = @import("../root.zig").steadyMillis;

fd: i32,
impls: std.ArrayList(*const ProtocolClientImplementation) = .empty,
server_specs: std.ArrayList(*const ProtocolSpec) = .empty,
pollfds: std.ArrayList(posix.pollfd) = .empty,
objects: std.ArrayList(ClientObject) = .empty,
@"error": bool = false,

const Self = @This();

pub fn open(gpa: mem.Allocator, path: [:0]const u8) !Self {
    _ = path;
    const sock = try gpa.create(Self);
    sock.* = .{};
}

pub fn attempt(self: *Self, path: [:0]const u8) void {
    self.fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    var server_address: posix.sockaddr.un = .{
        .path = undefined,
    };

    try fs.cwd().access(path, .{});

    if (path.len >= 108) return error.PathTooLong;

    @memcpy(&server_address.path, path.ptr);

    const failure = blk: {
        posix.connect(self.fd, @ptrCast(&server_address), @intCast(helpers.sunLen(&server_address))) catch |err| {
            if (err != error.ConnectionRefused) {
                return err;
            }

            break :blk true;
        };
        break :blk false;
    };
    _ = failure;
}

pub fn sendMessage(self: *Self, gpa: mem.Allocator, message: *const Message) void {
    const parsed = message.parseData(gpa) catch |err| {
        log.debug("[{} @ {}] -> parse error: {}", .{ self.fd, steadyMillis(), err });
        return;
    };
    defer gpa.free(parsed);
    log.debug("[{} @ {}] -> {s}", .{ self.fd, steadyMillis(), parsed });
}
