const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const fs = std.fs;

const helpers = @import("helpers");
const Fd = helpers.Fd;
const Io = std.Io;
const isTrace = helpers.isTrace;

const types = @import("../implementation/types.zig");
const ProtocolServerImplementation = types.server.ProtocolImplementation;
const message_parser = @import("../message/MessageParser.zig");
const FatalError = @import("../message/messages/FatalProtocolError.zig");
const Message = @import("../message/messages/root.zig").Message;
const RoundtripDone = @import("../message/messages/RoundtripDone.zig");
const root = @import("../root.zig");
const steadyMillis = root.steadyMillis;
const SocketRawParsedMessage = @import("../socket/socket_helpers.zig").SocketRawParsedMessage;
const ServerClient = @import("ServerClient.zig");
const ServerObject = @import("ServerObject.zig");

const log = std.log.scoped(.hw);
const Self = @This();

server: ?Io.net.Server = null,
export_fd: ?Fd = null,
export_write_fd: ?Fd = null,
exit_fd: Fd,
exit_write_fd: Fd,
wakeup_fd: Fd,
wakeup_write_fd: Fd,
pollfds: std.ArrayList(posix.pollfd) = .empty,
clients: std.ArrayList(*ServerClient) = .empty,
impls: std.ArrayList(ProtocolServerImplementation) = .empty,
thread_can_poll: bool = false,
poll_thread: ?std.Thread = null,
poll_mtx: std.Thread.Mutex.Recursive = .init,
export_poll_mtx: Io.Mutex = .init,
export_poll_mtx_locked: bool = false,
is_empty_listener: bool = false,
path: ?[:0]const u8 = null,

pub fn open(gpa: mem.Allocator, io: std.Io, path: ?[:0]const u8) !*Self {
    const socket = try gpa.create(Self);
    errdefer gpa.destroy(socket);

    socket.* = try Self.init();
    errdefer socket.deinit(gpa, io);

    if (path) |p| {
        try socket.attempt(io, p);
    } else {
        try socket.attemptEmpty();
    }

    try socket.recheckPollFds(gpa);

    return socket;
}

fn init() !Self {
    var wake_pipes: [2]i32 = undefined;
    var exit_pipes: [2]i32 = undefined;
    _ = posix.system.pipe2(&wake_pipes, .{ .CLOEXEC = true });
    _ = posix.system.pipe2(&exit_pipes, .{ .CLOEXEC = true });

    return .{
        .wakeup_fd = Fd{ .raw = wake_pipes[0] },
        .wakeup_write_fd = Fd{ .raw = wake_pipes[1] },
        .exit_fd = Fd{ .raw = exit_pipes[0] },
        .exit_write_fd = Fd{ .raw = exit_pipes[1] },
    };
}

pub fn deinit(self: *Self, gpa: mem.Allocator, io: Io) void {
    for (self.clients.items) |client| {
        client.deinit(gpa, io);
        gpa.destroy(client);
    }
    self.clients.deinit(gpa);
    self.impls.deinit(gpa);
    if (self.poll_thread) |*thread| {
        self.thread_can_poll = false;

        var file = self.exit_write_fd.asFile();
        var buffer: [1]u8 = undefined;
        var writer = file.writer(io, &buffer);
        var iowriter = &writer.interface;
        iowriter.writeAll("x") catch {};
        iowriter.flush() catch {};

        if (self.export_poll_mtx_locked) {
            self.export_poll_mtx.unlock(io);
        }
        thread.join();
    }
    if (self.export_fd) |*fd| fd.close(io);
    if (self.export_write_fd) |*fd| fd.close(io);
    self.exit_fd.close(io);
    self.exit_write_fd.close(io);
    if (self.server) |*server| server.deinit(io);
    self.pollfds.deinit(gpa);
    gpa.destroy(self);
}

pub fn attempt(self: *Self, io: std.Io, path: [:0]const u8) !void {
    if (std.Io.Dir.accessAbsolute(io, path, .{})) {
        var address = try Io.net.UnixAddress.init(path);

        if (address.connect(io)) |stream| {
            stream.close(io);
            return;
        } else |_| {
            try std.Io.Dir.deleteFileAbsolute(io, path);
        }
    } else |_| {}

    var address = try Io.net.UnixAddress.init(path);
    const server = try address.listen(io, .{ .kernel_backlog = 100 });

    self.path = path;
    self.server = server;
}

pub fn attemptEmpty(self: *Self) !void {
    self.is_empty_listener = true;
}

pub fn addImplementation(self: *Self, gpa: mem.Allocator, impl: ProtocolServerImplementation) !void {
    try self.impls.append(gpa, impl);
}

pub fn dispatchPending(self: *Self, gpa: mem.Allocator, io: Io) !bool {
    if (self.pollfds.items.len == 0) return false;
    _ = try posix.poll(self.pollfds.items, 0);
    if (self.dispatchNewConnections(gpa))
        return self.dispatchPending(gpa, io);

    return self.dispatchExistingConnections(gpa, io);
}

pub fn dispatchEvents(self: *Self, gpa: mem.Allocator, io: Io, block: bool) !bool {
    self.poll_mtx.lock();

    while (try self.dispatchPending(gpa, io)) {}

    self.clearEventFd(io);
    self.clearWakeupFd(io);

    if (block) {
        _ = try posix.poll(self.pollfds.items, -1);
        while (try self.dispatchPending(gpa, io)) {}
    }

    self.poll_mtx.unlock();

    if (self.export_poll_mtx_locked) {
        self.export_poll_mtx.unlock(io);
        self.export_poll_mtx_locked = false;
    }

    return true;
}

pub fn clearFd(io: Io, fd: Fd) void {
    var buf: [128]u8 = undefined;
    var fds = [_]posix.pollfd{.{ .fd = fd.raw, .events = posix.POLL.IN, .revents = 0 }};

    while (fd.isValid()) {
        _ = posix.poll(&fds, 0) catch break;

        if (fds[0].revents & posix.POLL.IN != 0) {
            var file = fd.asFile();
            var buffer: [128]u8 = undefined;
            var reader = file.reader(io, &buffer);
            var ioreader = reader.interface;
            ioreader.readSliceAll(&buf) catch break;
            continue;
        }

        break;
    }
}

pub fn clearEventFd(self: *Self, io: Io) void {
    if (self.export_fd) |fd| {
        clearFd(io, fd);
    }
}

pub fn clearWakeupFd(self: *Self, io: Io) void {
    clearFd(io, self.wakeup_fd);
}

pub fn addClient(self: *Self, gpa: mem.Allocator, io: std.Io, fd: Fd) !*ServerClient {
    const x = try ServerClient.init(fd);

    const client = try gpa.create(ServerClient);
    errdefer gpa.destroy(client);
    client.* = x;

    _ = try posix.fcntl(fd, posix.F.GETFL, 0);

    client.self = client;
    client.server = self;
    try self.clients.append(gpa, client);
    errdefer _ = self.clients.pop();

    try self.recheckPollFds(gpa);

    var file = self.wakeup_write_fd.asFile();
    var buffer: [1]u8 = undefined;
    var writer = file.writer(io, &buffer);
    var iowriter = &writer.interface;
    try iowriter.writeAll("x");
    try iowriter.flush();

    return client;
}

pub fn removeClient(self: *Self, gpa: mem.Allocator, io: Io, fd: Fd) bool {
    var removed: u32 = 0;

    var i: usize = self.clients.items.len;
    while (i > 0) : (i -= 1) {
        const client = self.clients.items[i];
        if (client.stream == fd) {
            var c = self.clients.swapRemove(i);
            c.deinit(gpa, io);
            gpa.destroy(c);
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
        const server = self.server orelse return error.NoFileDescriptor;
        try self.pollfds.append(gpa, .{
            .fd = server.socket.handle,
            .events = posix.POLL.IN,
            .revents = 0,
        });
    }

    try self.pollfds.append(gpa, .{
        .fd = self.exit_fd.raw,
        .events = posix.POLL.IN,
        .revents = 0,
    });

    try self.pollfds.append(gpa, .{
        .fd = self.wakeup_fd.raw,
        .events = posix.POLL.IN,
        .revents = 0,
    });

    for (self.clients.items) |client| {
        try self.pollfds.append(gpa, .{
            .fd = client.stream.socket.handle,
            .events = posix.POLL.IN,
            .revents = 0,
        });
    }
}

pub fn dispatchNewConnections(self: *Self, gpa: mem.Allocator) bool {
    const server = self.server orelse return false;

    if (self.is_empty_listener) return false;

    if ((self.pollfds.items[0].revents & posix.POLL.IN) == 0) return false;

    const client_fd = helpers.socket.accept(server.socket.handle, null, null, 0) catch return false;
    const x = gpa.create(ServerClient) catch {
        posix.close(client_fd);
        return false;
    };
    x.* = ServerClient.init(client_fd) catch {
        posix.close(client_fd);
        return false;
    };
    x.server = self;
    x.self = x;

    self.clients.append(gpa, x) catch {
        gpa.destroy(x);
        return false;
    };

    self.recheckPollFds(gpa) catch return false;

    return true;
}

pub fn dispatchExistingConnections(self: *Self, gpa: mem.Allocator, io: Io) !bool {
    var had_any = false;
    var needs_poll_recheck = false;

    var i = self.internalFds();
    while (i < self.pollfds.items.len) : (i += 1) {
        if ((self.pollfds.items[i].revents & posix.POLL.IN) == 0) continue;

        try self.dispatchClient(gpa, io, self.clients.items[i - self.internalFds()]);

        had_any = true;

        if ((self.pollfds.items[i].revents & posix.POLL.HUP) != 0) {
            self.clients.items[i - self.internalFds()].@"error" = true;
            needs_poll_recheck = true;
            if (isTrace()) {
                log.debug(
                    "[{} @ {}] Dropping client (hangup)",
                    .{ self.clients.items[i - self.internalFds()].stream.socket.handle, steadyMillis() },
                );
            }
            continue;
        }

        if (isTrace() and self.clients.items[i - self.internalFds()].@"error") {
            log.debug(
                "[{} @ {}] Dropping client (protocol error)",
                .{ self.clients.items[i - self.internalFds()].stream.socket.handle, steadyMillis() },
            );
        }
    }

    if (needs_poll_recheck) {
        i = self.clients.items.len;
        while (i > 0) : (i -= 1) {
            const client = self.clients.items[i - 1];
            if (client.@"error") {
                var c = self.clients.swapRemove(i - 1);
                c.deinit(gpa, io);
                gpa.destroy(c);
            }
        }
        try self.recheckPollFds(gpa);
    }

    return had_any;
}

pub fn dispatchClient(self: *Self, gpa: mem.Allocator, io: Io, client: *ServerClient) !void {
    _ = self;
    var data = try SocketRawParsedMessage.fromFd(gpa, client.stream.socket.handle);
    defer data.deinit(gpa);
    if (data.bad) {
        var fatal_msg = FatalError.init(gpa, 0, 0, "fatal: invalid message on wire") catch |err| {
            log.err("Failed to create fatal error message: {}", .{err});
            client.@"error" = true;
            return;
        };
        defer fatal_msg.deinit(gpa);
        client.sendMessage(gpa, io, Message.from(&fatal_msg));
        client.@"error" = true;
        return;
    }

    if (data.data.items.len == 0) return;

    message_parser.handleMessage(gpa, io, &data, .{ .server = client }) catch {
        var fatal_msg = try FatalError.init(gpa, 0, 0, "fatal: failed to handle message on wire");
        client.sendMessage(gpa, io, Message.from(&fatal_msg));
        client.@"error" = true;
        return;
    };

    if (client.scheduled_roundtrip_seq > 0) {
        var roundtrip_done = try RoundtripDone.init(gpa, client.scheduled_roundtrip_seq);
        defer roundtrip_done.deinit(gpa);
        client.sendMessage(gpa, io, Message.from(&roundtrip_done));
        client.scheduled_roundtrip_seq = 0;
    }
}

fn threadCallback(self: *Self, gpa: mem.Allocator, io: std.Io) void {
    while (self.thread_can_poll) {
        self.export_poll_mtx.lock(); // wait for dispatch to unlock
        self.export_poll_mtx_locked = true;

        if (!self.thread_can_poll) break;

        self.poll_mtx.lock();

        var pollfds = std.ArrayList(posix.pollfd).init(gpa);
        defer pollfds.deinit();

        if (!self.is_empty_listener) {
            if (self.server) |server| {
                pollfds.append(.{
                    .fd = server.raw,
                    .events = posix.POLL.IN,
                }) catch {
                    self.poll_mtx.unlock();
                    continue;
                };
            }
        }

        if (self.exit_fd) |exit_fd| {
            pollfds.append(.{
                .fd = exit_fd.raw,
                .events = posix.POLL.IN,
            }) catch {
                self.poll_mtx.unlock();
                continue;
            };
        }

        pollfds.append(.{
            .fd = self.wakeup_fd.raw,
            .events = posix.POLL.IN,
        }) catch {
            self.poll_mtx.unlock();
            continue;
        };

        for (self.clients.items) |client| {
            pollfds.append(.{
                .fd = client.stream.socket.handle,
                .events = posix.POLL.IN,
            }) catch {
                self.poll_mtx.unlock();
                continue;
            };
        }

        self.poll_mtx.unlock();

        if (pollfds.items.len == 0) continue;

        posix.poll(pollfds.items, -1) catch continue;

        if (self.export_write_fd) |export_write_fd| {
            var file = export_write_fd.asFile();
            var buffer: [1]u8 = undefined;
            var writer = file.writer(io, &buffer);
            var iowriter = &writer.interface;
            try iowriter.writeAll("x");
            try iowriter.flush();
        }
    }
}

pub fn extractLoopFD(self: *Self, gpa: mem.Allocator) !i32 {
    if (self.export_fd) |fd| {
        if (fd.isValid()) {
            return fd.raw;
        }
    }

    const export_pipes = try posix.pipe2(.{ .CLOEXEC = true });
    self.export_fd = Fd{ .raw = export_pipes[0] };
    errdefer {
        if (self.export_fd) |*fd| fd.close();
        self.export_fd = null;
    }
    self.export_write_fd = Fd{ .raw = export_pipes[1] };
    errdefer {
        if (self.export_write_fd) |*fd| fd.close();
        self.export_write_fd = null;
    }

    if (self.exit_fd == null or self.exit_write_fd == null) {
        const exit_pipes = try posix.pipe2(.{ .CLOEXEC = true });
        self.exit_fd = Fd{ .raw = exit_pipes[0] };
        errdefer {
            if (self.exit_fd) |*fd| fd.close();
            self.exit_fd = null;
        }
        self.exit_write_fd = Fd{ .raw = exit_pipes[1] };
        errdefer {
            if (self.exit_write_fd) |*fd| fd.close();
            self.exit_write_fd = null;
        }
    }

    self.thread_can_poll = true;
    errdefer self.thread_can_poll = false;

    try self.recheckPollFds(gpa);

    self.poll_thread = try std.Thread.spawn(.{}, threadCallback, .{ self, gpa });

    const export_fd = self.export_fd orelse return error.NoEventFd;
    return export_fd.raw;
}

pub fn createObject(self: *Self, gpa: mem.Allocator, io: Io, client: ?*ServerClient, reference: ?*ServerObject, object: []const u8, seq: u32) ?*ServerObject {
    _ = self;
    if (client == null or reference == null) {
        return null;
    }

    if (reference) |ref| {
        if (client) |c| {
            const protocol_name = ref.protocol_name;
            const version = ref.version;

            return c.createObject(gpa, io, protocol_name, object, version, seq);
        }
    }

    return null;
}
