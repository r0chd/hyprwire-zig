const std = @import("std");
const types = @import("../implementation/types.zig");
const message_parser = @import("../message/MessageParser.zig");
const root = @import("../root.zig");

const ServerObject = @import("ServerObject.zig");
const ServerClient = @import("ServerClient.zig");
const SocketRawParsedMessage = @import("../socket/socket_helpers.zig").SocketRawParsedMessage;
const FatalError = @import("../message/messages/FatalProtocolError.zig");
const RoundtripDone = @import("../message/messages/RoundtripDone.zig");

const ProtocolServerImplementation = types.ProtocolServerImplementation;
const MessageParsingResult = message_parser.MessageParsingResult;

const mem = std.mem;
const posix = std.posix;
const fs = std.fs;
const log = std.log;

const sunLen = root.sunLen;
const steadyMillis = root.steadyMillis;

const Self = @This();

fd: i32 = -1,
export_fd: i32 = -1,
export_write_fd: i32 = -1,
exit_fd: i32 = -1,
exit_write_fd: i32 = -1,
wakeup_fd: i32,
wakeup_write_fd: i32,
pollfds: std.ArrayList(posix.pollfd) = .empty,
clients: std.ArrayList(*ServerClient) = .empty,
impls: std.ArrayList(*const ProtocolServerImplementation) = .empty,
thread_can_poll: bool = false,
poll_thread: ?std.Thread = null,
poll_mtx: std.Thread.Mutex.Recursive = .init,
export_poll_mtx: std.Thread.Mutex = .{},
export_poll_mtx_locked: bool = false,
is_empty_listener: bool = false,
path: ?[:0]const u8 = null,

fn init() !Self {
    const pipes = try posix.pipe2(.{
        .CLOEXEC = true,
    });

    return .{
        .wakeup_fd = pipes[0],
        .wakeup_write_fd = pipes[1],
    };
}

pub fn open(gpa: mem.Allocator, path: ?[:0]const u8) !?*Self {
    const socket = try gpa.create(Self);
    errdefer gpa.destroy(socket);
    socket.* = try Self.init();

    if (path) |p| {
        if (!socket.attempt(gpa, p)) return null;
    } else {
        if (!socket.attemptEmpty(gpa)) return null;
    }

    return socket;
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    self.pollfds.deinit(gpa);
    gpa.destroy(self);
}

pub fn attempt(self: *Self, gpa: mem.Allocator, path: [:0]const u8) bool {
    if (posix.access(path, posix.F_OK)) {
        self.fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return false;
        var server_address: posix.sockaddr.un = .{
            .path = undefined,
        };

        if (path.len >= 108) return false;

        @memcpy(&server_address.path, path.ptr);

        const failure = blk: {
            posix.connect(self.fd, @ptrCast(&server_address), @intCast(sunLen(&server_address))) catch |err| {
                if (err != error.ConnectionRefused) {
                    return false;
                }

                break :blk true;
            };
            break :blk false;
        };

        if (!failure) {
            posix.close(self.fd);
            self.fd = -1;
            return false;
        }

        posix.close(self.fd);
        self.fd = -1;

        fs.deleteFileAbsolute(path) catch return false;
    } else |_| {}

    self.fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch return false;
    var server_address: posix.sockaddr.un = .{
        .path = undefined,
    };

    if (path.len >= 108) return false;

    @memcpy(&server_address.path, path.ptr);

    posix.bind(self.fd, @ptrCast(&server_address), @intCast(sunLen(&server_address))) catch return false;

    posix.listen(self.fd, 100) catch return false;

    const current_fd_flags = posix.fcntl(self.fd, posix.F.GETFD, 0) catch return false;
    _ = posix.fcntl(self.fd, posix.F.SETFD, current_fd_flags | posix.FD_CLOEXEC) catch return false;
    const current_flags = posix.fcntl(self.fd, posix.F.GETFL, 0) catch return false;
    _ = posix.fcntl(self.fd, posix.F.SETFL, current_flags | (1 << @bitOffsetOf(posix.O, "NONBLOCK"))) catch return false;
    self.path = path;

    self.recheckPollFds(gpa) catch return false;
    return true;
}

pub fn attemptEmpty(self: *Self, gpa: mem.Allocator) bool {
    self.is_empty_listener = true;

    self.recheckPollFds(gpa) catch return false;

    return true;
}

pub fn addImplementation(self: *Self, gpa: mem.Allocator, impl: *const ProtocolServerImplementation) !void {
    try self.impls.append(gpa, impl);
}

pub fn dispatchPending(self: *Self, gpa: mem.Allocator) bool {
    _ = posix.poll(self.pollfds.items, 0) catch return false;
    if (self.dispatchNewConnections(gpa)) return self.dispatchPending(gpa);

    return self.dispatchExistingConnections(gpa);
}

pub fn dispatchEvents(self: *Self, gpa: mem.Allocator, block: bool) bool {
    self.poll_mtx.lock();
    defer self.poll_mtx.unlock();

    while (self.dispatchPending(gpa)) {}

    self.clearEventFd();
    self.clearWakeupFd();

    if (block) {
        _ = posix.poll(self.pollfds.items, -1) catch return false;
        while (self.dispatchPending(gpa)) {}
    }

    if (self.export_poll_mtx_locked) {
        self.export_poll_mtx.unlock();
        self.export_poll_mtx_locked = false;
    }

    return true;
}

pub fn clearFd(fd: i32) void {
    var buf: [128]u8 = undefined;
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};

    while (true) {
        _ = posix.poll(&fds, 0) catch break;

        if (fds[0].revents & posix.POLL.IN != 0) {
            _ = posix.read(fd, &buf) catch break;
            continue;
        }
    }
}

pub fn clearEventFd(self: *Self) void {
    clearFd(self.export_fd);
}

pub fn clearWakeupFd(self: *Self) void {
    clearFd(self.wakeup_fd);
}

pub fn addClient(self: *Self, gpa: mem.Allocator, fd: i32) ?*ServerClient {
    const x = ServerClient.init(fd) catch return null;
    const client = gpa.create(ServerClient) catch return null;
    client.* = x;

    const valid = posix.fcntl(fd, posix.F.GETFL, 0) catch |err| switch (err) {
        else => {
            gpa.destroy(client);
            return null;
        },
    };
    _ = valid;

    client.self = client;
    client.server = self;
    self.clients.append(gpa, client) catch {
        gpa.destroy(client);
        return null;
    };

    self.recheckPollFds(gpa) catch {
        _ = self.clients.pop();
        gpa.destroy(client);
        return null;
    };

    const write_buf: [1]u8 = .{'x'};
    _ = posix.write(self.wakeup_write_fd, &write_buf) catch {};

    return client;
}

pub fn removeClient(self: *Self, gpa: mem.Allocator, fd: i32) bool {
    var removed: u32 = 0;

    var i: usize = self.clients.items.len;
    while (i > 0) : (i -= 1) {
        const client = self.clients.items[i];
        if (client.fd == fd) {
            self.clients.swapRemove(i);
            removed += 1;
        }
    }

    if (removed > 0) self.recheckPollFds(gpa) catch return false;

    return removed > 0;
}

pub fn internalFds(self: *Self) usize {
    return if (self.is_empty_listener) 2 else 3;
}

pub fn recheckPollFds(self: *Self, gpa: mem.Allocator) !void {
    self.pollfds.clearAndFree(gpa);

    if (!self.is_empty_listener) {
        try self.pollfds.append(gpa, .{
            .fd = self.fd,
            .events = posix.POLL.IN,
            .revents = 0,
        });
    }

    try self.pollfds.append(gpa, .{
        .fd = self.exit_fd,
        .events = posix.POLL.IN,
        .revents = 0,
    });

    try self.pollfds.append(gpa, .{
        .fd = self.wakeup_fd,
        .events = posix.POLL.IN,
        .revents = 0,
    });

    for (self.clients.items) |client| {
        try self.pollfds.append(gpa, .{
            .fd = client.fd,
            .events = posix.POLL.IN,
            .revents = 0,
        });
    }
}

pub fn dispatchNewConnections(self: *Self, gpa: mem.Allocator) bool {
    if (self.is_empty_listener) return false;

    if (self.pollfds.items[0].revents & posix.POLL.IN != 0) return false;

    var client_address: posix.sockaddr.in = .{
        .port = 0,
        .addr = 0,
    };
    var client_size: posix.socklen_t = @sizeOf(posix.sockaddr.in);

    const client_fd = posix.accept(self.fd, @as(*posix.sockaddr, @ptrCast(&client_address.addr)), &client_size, 0) catch return false;
    const client_init = ServerClient.init(client_fd) catch {
        posix.close(client_fd);
        return false;
    };
    const x = gpa.create(ServerClient) catch {
        posix.close(client_fd);
        return false;
    };
    x.* = client_init;
    x.server = self;
    x.self = x;

    self.clients.append(gpa, x) catch {
        gpa.destroy(x);
        return false;
    };

    self.recheckPollFds(gpa) catch return false;

    return true;
}

pub fn dispatchExistingConnections(self: *Self, gpa: mem.Allocator) bool {
    var had_any = false;
    var needs_poll_recheck = false;

    for (self.internalFds()..self.pollfds.items.len) |i| {
        if (self.pollfds.items[i].revents & posix.POLL.IN != 0) continue;

        self.dispatchClient(gpa, self.clients.items[i - self.internalFds()]) catch return false;

        had_any = true;

        if (self.pollfds.items[i].revents & posix.POLL.HUP == 0) {
            self.clients.items[i - self.internalFds()].err = true;
            needs_poll_recheck = true;
            log.debug("[{} @ {}] Dropping client (hangup)", .{ self.clients.items[i - self.internalFds()].fd, steadyMillis() });
            continue;
        }

        if (self.clients.items[i - self.internalFds()].err) {
            log.debug("[{} @ {}] Dropping client (protocol error)", .{ self.clients.items[i - self.internalFds()].fd, steadyMillis() });
        }
    }

    if (needs_poll_recheck) {
        var i: usize = self.clients.items.len;
        while (i > 0) : (i -= 1) {
            const client = self.clients.items[i];
            if (client.err) {
                _ = self.clients.swapRemove(i);
            }
        }
        self.recheckPollFds(gpa) catch return false;
    }

    return had_any;
}

pub fn dispatchClient(self: *Self, gpa: mem.Allocator, client: *ServerClient) !void {
    _ = self;
    const data = try SocketRawParsedMessage.fromFd(gpa, client.fd);
    if (data.bad) {
        const fatal_msg = FatalError.init(gpa, 0, 0, "fatal: invalid message on wire") catch |err| {
            log.err("Failed to create fatal error message: {}", .{err});
            client.err = true;
            return;
        };
        client.sendMessage(gpa, fatal_msg);
        client.err = true;
        return;
    }

    if (data.data.items.len == 0) return;

    const ret = message_parser.message_parser.handleMessageServer(data, client);
    if (ret != MessageParsingResult.ok) {
        const fatal_msg = FatalError.init(gpa, 0, 0, "fatal: failed to handle message on wire") catch |err| {
            log.err("Failed to create fatal error message: {}", .{err});
            client.err = true;
            return;
        };
        client.sendMessage(gpa, fatal_msg);
        client.err = true;
        return;
    }

    if (client.scheduled_roundtrip_seq > 0) {
        client.sendMessage(gpa, RoundtripDone.init(client.scheduled_roundtrip_seq));
        client.scheduled_roundtrip_seq = 0;
    }
}

pub fn extractLoopFD(self: *Self, gpa: mem.Allocator) !i32 {
    const export_fd_valid = posix.fcntl(self.export_fd, posix.F.GETFL, 0) catch |err| switch (err) {
        else => false,
    };

    if (!export_fd_valid or self.export_fd == -1) {
        const export_pipes = try posix.pipe2(posix.FD_CLOEXEC);
        self.export_fd = export_pipes[0];
        self.export_write_fd = export_pipes[1];

        const exit_pipes = try posix.pipe2(posix.FD_CLOEXEC);
        self.exit_fd = exit_pipes[0];
        self.exit_write_fd = exit_pipes[1];

        self.thread_can_poll = true;

        try self.recheckPollFds(gpa);

        self.poll_thread = try std.Thread.spawn(.{}, pollThread, .{self});
    }

    return self.export_fd;
}

pub fn createObject(gpa: mem.Allocator, client: ?*ServerClient, reference: ?*ServerObject, object: []const u8, seq: u32) ?*ServerObject {
    if (client == null or reference == null) {
        return null;
    }

    if (reference) |ref| {
        if (client) |c| {
            const protocol_name = ref.base.protocol_name;
            const version = ref.base.version;

            const new_object = c.createObject(gpa, protocol_name, object, version, seq) catch return null;
            return new_object;
        }
    }

    return null;
}

fn pollThread(self: *Self) void {
    var pollfds = std.ArrayList(posix.pollfd).init(std.heap.page_allocator);
    defer pollfds.deinit();

    while (self.thread_can_poll) {
        self.export_poll_mtx.lock();
        self.export_poll_mtx_locked = true;

        if (!self.thread_can_poll) {
            break;
        }

        self.poll_mtx.lock();

        pollfds.clearRetainingCapacity();

        if (!self.is_empty_listener and self.fd) |fd| {
            pollfds.append(.{
                .fd = fd,
                .events = posix.POLL.IN,
            }) catch {
                self.poll_mtx.unlock();
                continue;
            };
        }

        pollfds.append(.{
            .fd = self.exit_fd,
            .events = posix.POLL.IN,
        }) catch {
            self.poll_mtx.unlock();
            continue;
        };

        pollfds.append(.{
            .fd = self.wakeup_fd,
            .events = posix.POLL.IN,
        }) catch {
            self.poll_mtx.unlock();
            continue;
        };

        for (self.clients.items) |client| {
            pollfds.append(.{
                .fd = client.fd,
                .events = posix.POLL.IN,
            }) catch {
                self.poll_mtx.unlock();
                continue;
            };
        }

        self.poll_mtx.unlock();

        _ = posix.poll(pollfds.items, -1) catch break;

        const write_buf: [1]u8 = .{'x'};
        _ = posix.write(self.export_write_fd, &write_buf) catch {};
    }
}
