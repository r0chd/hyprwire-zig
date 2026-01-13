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
const Fd = helpers.Fd;

const steadyMillis = @import("../root.zig").steadyMillis;

fd: Fd,
impls: std.ArrayList(*const ProtocolClientImplementation) = .empty,
server_specs: std.ArrayList(*const ProtocolSpec) = .empty,
pollfds: std.ArrayList(posix.pollfd) = .empty,
objects: std.ArrayList(ClientObject) = .empty,
@"error": bool = false,

const Self = @This();

pub fn open(gpa: mem.Allocator, source: union(enum) { fd: i32, path: [:0]const u8 }) !*Self {
    const sock = try gpa.create(Self);
    errdefer gpa.destroy(sock);
    sock.* = .{ .fd = undefined };

    switch (source) {
        .fd => |fd| try sock.attemptFromFd(gpa, fd),
        .path => |path| try sock.attempt(gpa, path),
    }

    return sock;
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    self.pollfds.deinit(gpa);
    self.fd.close();
    gpa.destroy(self);
}

pub fn attempt(self: *Self, gpa: mem.Allocator, path: [:0]const u8) !void {
    const raw_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    const fd = Fd{ .raw = raw_fd };

    var server_address: posix.sockaddr.un = .{
        .path = undefined,
    };

    try fs.cwd().access(path, .{});

    if (path.len >= 108) return error.PathTooLong;

    @memcpy(&server_address.path, path.ptr);

    try posix.connect(fd.raw, @ptrCast(&server_address), @intCast(helpers.sunLen(&server_address)));

    try fd.setFlags(posix.FD_CLOEXEC | (1 << @bitOffsetOf(posix.O, "NONBLOCK")));

    try self.pollfds.append(gpa, .{
        .fd = fd.raw,
        .events = posix.POLL.IN,
        .revents = 0,
    });

    self.fd = fd;

    var message = Message.Hello.init();
    self.sendMessage(gpa, &message.interface);
}

pub fn attemptFromFd(self: *Self, gpa: mem.Allocator, raw_fd: i32) !void {
    const fd = Fd{ .raw = raw_fd };
    try fd.setFlags(posix.FD_CLOEXEC | (1 << @bitOffsetOf(posix.O, "NONBLOCK")));

    try self.pollfds.append(gpa, .{
        .fd = fd.raw,
        .events = posix.POLL.IN,
        .revents = 0,
    });

    self.fd = fd;

    var message = Message.Hello.init();
    self.sendMessage(gpa, &message.interface);
}

pub fn sendMessage(self: *Self, gpa: mem.Allocator, message: *const Message) void {
    const parsed = message.parseData(gpa) catch |err| {
        log.debug("[{} @ {}] -> parse error: {}", .{ self.fd.raw, steadyMillis(), err });
        return;
    };
    defer gpa.free(parsed);
    log.debug("[{} @ {}] -> {s}", .{ self.fd.raw, steadyMillis(), parsed });
}
