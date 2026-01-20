const std = @import("std");
const types = @import("../implementation/types.zig");
const message_parser = @import("../message/MessageParser.zig");
const root = @import("../root.zig");
const helpers = @import("helpers");

const Message = @import("../message/messages/root.zig").Message;
const ServerObject = @import("ServerObject.zig");
const ServerClient = @import("ServerClient.zig");
const SocketRawParsedMessage = @import("../socket/socket_helpers.zig").SocketRawParsedMessage;
const FatalError = @import("../message/messages/FatalProtocolError.zig");
const RoundtripDone = @import("../message/messages/RoundtripDone.zig");

const ProtocolServerImplementation = types.server_impl.ProtocolServerImplementation;
const MessageParsingResult = message_parser.MessageParsingResult;
const Fd = helpers.Fd;

const isTrace = helpers.isTrace;
const mem = std.mem;
const posix = std.posix;
const fs = std.fs;
const log = std.log.scoped(.hw);
const steadyMillis = root.steadyMillis;

const Self = @This();

fd: ?Fd = null,
export_fd: ?Fd = null,
export_write_fd: ?Fd = null,
exit_fd: ?Fd = null,
exit_write_fd: ?Fd = null,
wakeup_fd: Fd,
wakeup_write_fd: Fd,
pollfds: std.ArrayList(posix.pollfd) = .empty,
clients: std.ArrayList(*ServerClient) = .empty,
impls: std.ArrayList(ProtocolServerImplementation) = .empty,
thread_can_poll: bool = false,
poll_thread: ?std.Thread = null,
poll_mtx: std.Thread.Mutex.Recursive = .init,
export_poll_mtx: std.Thread.Mutex = .{},
export_poll_mtx_locked: bool = false,
is_empty_listener: bool = false,
path: ?[:0]const u8 = null,

pub fn open(gpa: mem.Allocator, path: ?[:0]const u8) !*Self {
    const socket = try gpa.create(Self);
    errdefer gpa.destroy(socket);

    const pipes = try posix.pipe2(.{ .CLOEXEC = true });
    socket.* = .{
        .wakeup_fd = Fd{ .raw = pipes[0] },
        .wakeup_write_fd = Fd{ .raw = pipes[1] },
    };

    if (path) |p| {
        try socket.attempt(gpa, p);
    } else {
        try socket.attemptEmpty(gpa);
    }

    return socket;
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    self.impls.deinit(gpa);
    if (self.poll_thread) |*thread| {
        self.thread_can_poll = false;
        if (self.exit_write_fd) |fd| {
            const write_buf: [1]u8 = .{'x'};
            _ = posix.write(fd.raw, &write_buf) catch {};
        }
        if (self.export_poll_mtx_locked) {
            self.export_poll_mtx.unlock();
        }
        thread.join();
    }

    if (self.export_fd) |*fd| fd.close();
    if (self.export_write_fd) |*fd| fd.close();
    if (self.exit_fd) |*fd| fd.close();
    if (self.exit_write_fd) |*fd| fd.close();
    if (self.fd) |*fd| fd.close();
    self.pollfds.deinit(gpa);
    gpa.destroy(self);
}

pub fn attempt(self: *Self, gpa: mem.Allocator, path: [:0]const u8) !void {
    if (posix.access(path, posix.F_OK)) {
        const raw_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        var fd = Fd{ .raw = raw_fd };
        defer fd.close();

        var server_address: posix.sockaddr.un = .{
            .path = undefined,
        };

        if (path.len >= 108) return error.PathTooLong;

        @memcpy(&server_address.path, path.ptr);

        const failure = blk: {
            posix.connect(fd.raw, @ptrCast(&server_address), @intCast(helpers.sunLen(&server_address))) catch |err| {
                if (err != error.ConnectionRefused) {
                    return err;
                }

                break :blk true;
            };
            break :blk false;
        };

        if (!failure) {
            return;
        }

        try fs.deleteFileAbsolute(path);
    } else |_| {}

    const raw_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    var fd = Fd{ .raw = raw_fd };
    errdefer fd.close();

    var server_address: posix.sockaddr.un = .{
        .path = undefined,
    };

    if (path.len >= 108) return error.PathTooLong;

    @memcpy(&server_address.path, path.ptr);

    try posix.bind(fd.raw, @ptrCast(&server_address), @intCast(helpers.sunLen(&server_address)));

    try posix.listen(fd.raw, 100);

    try fd.setFlags(posix.FD_CLOEXEC | (1 << @bitOffsetOf(posix.O, "NONBLOCK")));

    self.path = path;
    self.fd = fd;

    try self.recheckPollFds(gpa);
}

pub fn attemptEmpty(self: *Self, gpa: mem.Allocator) !void {
    self.is_empty_listener = true;

    try self.recheckPollFds(gpa);
}

pub fn addImplementation(self: *Self, gpa: mem.Allocator, impl: ProtocolServerImplementation) !void {
    try self.impls.append(gpa, impl);
}

pub fn dispatchPending(self: *Self, gpa: mem.Allocator) !bool {
    if (self.pollfds.items.len == 0) return false;
    _ = try posix.poll(self.pollfds.items, 0);
    if (self.dispatchNewConnections(gpa))
        return try self.dispatchPending(gpa);

    return try self.dispatchExistingConnections(gpa);
}

pub fn dispatchEvents(self: *Self, gpa: mem.Allocator, block: bool) !bool {
    self.poll_mtx.lock();
    defer self.poll_mtx.unlock();

    while (try self.dispatchPending(gpa)) {}

    self.clearEventFd();
    self.clearWakeupFd();

    if (block) {
        if (self.pollfds.items.len == 0) return true;
        _ = try posix.poll(self.pollfds.items, -1);
        while (try self.dispatchPending(gpa)) {}
    }

    if (self.export_poll_mtx_locked) {
        self.export_poll_mtx.unlock();
        self.export_poll_mtx_locked = false;
    }

    return true;
}

pub fn clearFd(fd: Fd) void {
    var buf: [128]u8 = undefined;
    var fds = [_]posix.pollfd{.{ .fd = fd.raw, .events = posix.POLL.IN, .revents = 0 }};

    while (true) {
        _ = posix.poll(&fds, 0) catch break;

        if (fds[0].revents & posix.POLL.IN != 0) {
            _ = posix.read(fd.raw, &buf) catch break;
            continue;
        }
    }
}

pub fn clearEventFd(self: *Self) void {
    if (self.export_fd) |fd| {
        clearFd(fd);
    }
}

pub fn clearWakeupFd(self: *Self) void {
    clearFd(self.wakeup_fd);
}

pub fn addClient(self: *Self, gpa: mem.Allocator, fd: Fd) ?*ServerClient {
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

pub fn removeClient(self: *Self, gpa: mem.Allocator, fd: Fd) bool {
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
        const fd = self.fd orelse return error.NoFileDescriptor;
        try self.pollfds.append(gpa, .{
            .fd = fd.raw,
            .events = posix.POLL.IN,
            .revents = 0,
        });
    }

    if (self.exit_fd) |exit_fd| {
        try self.pollfds.append(gpa, .{
            .fd = exit_fd.raw,
            .events = posix.POLL.IN,
            .revents = 0,
        });
    }

    try self.pollfds.append(gpa, .{
        .fd = self.wakeup_fd.raw,
        .events = posix.POLL.IN,
        .revents = 0,
    });

    for (self.clients.items) |client| {
        try self.pollfds.append(gpa, .{
            .fd = client.fd.raw,
            .events = posix.POLL.IN,
            .revents = 0,
        });
    }
}

pub fn dispatchNewConnections(self: *Self, gpa: mem.Allocator) bool {
    const fd = self.fd orelse return false;

    if (self.is_empty_listener) return false;

    if ((self.pollfds.items[0].revents & posix.POLL.IN) == 0) return false;

    var client_address: posix.sockaddr.in = .{
        .port = 0,
        .addr = 0,
    };
    var client_size: posix.socklen_t = @sizeOf(posix.sockaddr.in);

    const client_fd = posix.accept(fd.raw, @as(*posix.sockaddr, @ptrCast(&client_address.addr)), &client_size, 0) catch return false;
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

pub fn dispatchExistingConnections(self: *Self, gpa: mem.Allocator) !bool {
    var had_any = false;
    var needs_poll_recheck = false;

    for (self.internalFds()..self.pollfds.items.len) |i| {
        if ((self.pollfds.items[i].revents & posix.POLL.IN) == 0) continue;

        try self.dispatchClient(gpa, self.clients.items[i - self.internalFds()]);

        had_any = true;

        if ((self.pollfds.items[i].revents & posix.POLL.HUP) != 0) {
            self.clients.items[i - self.internalFds()].@"error" = true;
            needs_poll_recheck = true;
            if (isTrace()) {
                log.debug("[{} @ {}] Dropping client (hangup)", .{ self.clients.items[i - self.internalFds()].fd, steadyMillis() });
            }
            continue;
        }

        if (isTrace() and self.clients.items[i - self.internalFds()].@"error") {
            log.debug("[{} @ {}] Dropping client (protocol error)", .{ self.clients.items[i - self.internalFds()].fd, steadyMillis() });
        }
    }

    if (needs_poll_recheck) {
        var i: usize = self.clients.items.len;
        while (i > 0) : (i -= 1) {
            const client = self.clients.items[i - 1];
            if (client.@"error") {
                _ = self.clients.swapRemove(i - 1);
            }
        }
        try self.recheckPollFds(gpa);
    }

    return had_any;
}

pub fn dispatchClient(self: *Self, gpa: mem.Allocator, client: *ServerClient) !void {
    _ = self;
    var data = try SocketRawParsedMessage.fromFd(gpa, client.fd.raw);
    if (data.bad) {
        var fatal_msg = FatalError.init(gpa, 0, 0, "fatal: invalid message on wire") catch |err| {
            log.err("Failed to create fatal error message: {}", .{err});
            client.@"error" = true;
            return;
        };
        client.sendMessage(gpa, Message.from(&fatal_msg));
        client.@"error" = true;
        return;
    }

    if (data.data.items.len == 0) return;

    const ret = message_parser.handleMessage(gpa, &data, .{ .server = client });
    if (ret != MessageParsingResult.ok) {
        var fatal_msg = try FatalError.init(gpa, 0, 0, "fatal: failed to handle message on wire");
        client.sendMessage(gpa, Message.from(&fatal_msg));
        client.@"error" = true;
        return;
    }

    if (client.scheduled_roundtrip_seq > 0) {
        var roundtrip_done = try RoundtripDone.init(gpa, client.scheduled_roundtrip_seq);
        defer roundtrip_done.deinit(gpa);
        client.sendMessage(gpa, Message.from(&roundtrip_done));
        client.scheduled_roundtrip_seq = 0;
    }
}

pub fn createObject(gpa: mem.Allocator, client: ?*ServerClient, reference: ?*ServerObject, object: []const u8, seq: u32) ?*ServerObject {
    if (client == null or reference == null) {
        return null;
    }

    if (reference) |ref| {
        if (client) |c| {
            const protocol_name = ref.protocol_name;
            const version = ref.version;

            const new_object = c.createObject(gpa, protocol_name, object, version, seq) catch return null;
            return new_object;
        }
    }

    return null;
}

fn pollThread(self: *Self, gpa: mem.Allocator) void {
    var pollfds: std.ArrayList(posix.pollfd) = .empty;
    defer pollfds.deinit(gpa);

    while (self.thread_can_poll) {
        self.export_poll_mtx.lock();
        self.export_poll_mtx_locked = true;

        if (!self.thread_can_poll) {
            break;
        }

        self.poll_mtx.lock();

        pollfds.clearRetainingCapacity();

        if (!self.is_empty_listener and self.fd) |fd| {
            pollfds.append(gpa, .{
                .fd = fd,
                .events = posix.POLL.IN,
            }) catch {
                self.poll_mtx.unlock();
                continue;
            };
        }

        if (self.exit_fd) |fd| {
            pollfds.append(gpa, .{
                .fd = fd.raw,
                .events = posix.POLL.IN,
            }) catch {
                self.poll_mtx.unlock();
                continue;
            };
        }

        pollfds.append(gpa, .{
            .fd = self.wakeup_fd,
            .events = posix.POLL.IN,
        }) catch {
            self.poll_mtx.unlock();
            continue;
        };

        for (self.clients.items) |client| {
            pollfds.append(gpa, .{
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
        if (self.export_write_fd) |fd| {
            _ = posix.write(fd.raw, &write_buf) catch {};
        }
    }
}
