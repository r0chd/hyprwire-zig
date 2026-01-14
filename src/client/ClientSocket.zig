const std = @import("std");
const types = @import("../implementation/types.zig");
const helpers = @import("helpers");
const message_parser = @import("../message/MessageParser.zig");

const Message = @import("../message/messages/root.zig");
const SocketRawParsedMessage = @import("../socket/socket_helpers.zig").SocketRawParsedMessage;

const mem = std.mem;
const posix = std.posix;
const log = std.log;
const fs = std.fs;

const ClientObject = @import("ClientObject.zig");

const ProtocolClientImplementation = types.ProtocolClientImplementation;
const ProtocolSpec = types.ProtocolSpec;
const Fd = helpers.Fd;

const steadyMillis = @import("../root.zig").steadyMillis;

const HANDSHAKE_MAX_MS: u64 = 5000;

fd: Fd,
impls: std.ArrayList(*const ProtocolClientImplementation) = .empty,
server_specs: std.ArrayList(*const ProtocolSpec) = .empty,
pollfds: std.ArrayList(posix.pollfd) = .empty,
objects: std.ArrayList(ClientObject) = .empty,
handshake_begin: std.time.Instant,
@"error": bool = false,
handshake_done: bool,
pending_socket_data: std.ArrayList(SocketRawParsedMessage) = .empty,

const Self = @This();

pub fn open(gpa: mem.Allocator, source: union(enum) { fd: i32, path: [:0]const u8 }) !*Self {
    const sock = try gpa.create(Self);
    errdefer gpa.destroy(sock);
    sock.* = .{
        .fd = undefined,
        .handshake_begin = try std.time.Instant.now(),
        .handshake_done = false,
    };

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
    self.sendMessage(gpa, message.message());
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
    self.sendMessage(gpa, message.message());
}

pub fn waitForHandshake(self: *Self) !void {
    self.handshake_begin = try std.time.Instant.now();

    while (!self.@"error" and !self.handshake_done) {}
}

pub fn dispatchEvents(self: *Self, gpa: mem.Allocator, block: bool) !void {
    if (self.@"error") return error.TODO;

    if (!self.handshake_done) {
        const now = std.time.Instant.now();
        const elapsed_ns = now.since(self.handshake_begin);

        const max_ms = std.math.max(HANDSHAKE_MAX_MS - @as(i64, elapsed_ns / std.time.ns_per_ms), 0);

        const ret = try posix.poll(self.pollfds.items, if (block) max_ms else 0);
        if (block and ret == 0) {
            log.debug("handshake error: timed out", .{});
            self.disconnectError();
            return error.TimedOut;
        }
    }

    if (self.pending_socket_data.items.len > 0) {
        const datas = try self.pending_socket_data.toOwnedSlice(gpa);
        for (datas) |data| {
            const ret = message_parser.message_parser.handleMessage(data, self);
            if (ret != .ok) {
                log.debug("fatal: failed to handle message on wire", .{});
                self.disconnectOnError();
                return error.FailedToHandleMessage;
            }
        }
    }

    if (self.handshake_done) {
        posix.poll(self.pollfds.items, if (block) -1 else 0);
    }

    const revents = self.pollfds.items[0].revents;
    if ((revents & posix.POLL.HUP) != 0) {
        return error.ConnectionClosed;
    } else if (revents & posix.POLL.IN == 0) {
        return;
    }

    // dispatch

    const data = try SocketRawParsedMessage.fromFd(gpa, self.fd);
    if (data.bad) {
        log.debug("fatal: received malformed message from server", .{});
        self.disconnectOnError();
        return error.MessageMalformed;
    }

    if (data.data.items.len == 0) return error.NoData;

    // const ret = message_parser.MessageParser.handleMessageServer(self: *MessageParser, data: SocketRawParsedMessage, client: *ServerClient)
}

pub fn sendMessage(self: *Self, gpa: mem.Allocator, message: Message) void {
    const parsed = message.parseData(gpa) catch |err| {
        log.debug("[{} @ {}] -> parse error: {}", .{ self.fd.raw, steadyMillis(), err });
        return;
    };
    defer gpa.free(parsed);
    log.debug("[{} @ {}] -> {s}", .{ self.fd.raw, steadyMillis(), parsed });
}

pub fn disconnectOnError(self: *Self) void {
    self.@"error" = true;
    self.fd.close();
}
