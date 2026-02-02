const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const Io = std.Io;

const helpers = @import("helpers");
const isTrace = helpers.isTrace;

const types = @import("../implementation/types.zig");
const ProtocolImplementation = types.server.ProtocolImplementation;
const message_parser = @import("../message/MessageParser.zig");
const FatalError = @import("../message/messages/FatalProtocolError.zig");
const RoundtripDone = @import("../message/messages/RoundtripDone.zig");
const root = @import("../root.zig");
const steadyMillis = root.steadyMillis;
const SocketRawParsedMessage = @import("../socket/SocketRawParsedMessage.zig");
const ServerClient = @import("ServerClient.zig");
const ServerObject = @import("ServerObject.zig");

const log = std.log.scoped(.hw);
const Self = @This();

server: ?Io.net.Server = null,
export_fd: ?Io.File = null,
export_write_fd: ?Io.File = null,
exit_fd: Io.File,
exit_write_fd: Io.File,
wakeup_fd: Io.File,
wakeup_write_fd: Io.File,
pollfds: std.ArrayList(posix.pollfd) = .empty,
clients: std.ArrayList(*ServerClient) = .empty,
impls: std.ArrayList(*const ProtocolImplementation) = .empty,
thread_can_poll: bool = false,
poll_thread: ?std.Thread = null,
poll_mtx: std.Thread.Mutex.Recursive = .init,
export_poll_mtx: std.Thread.Mutex = .{},
poll_event: bool = false,
poll_event_cv: std.Thread.Condition = .{},
is_empty_listener: bool = false,
path: ?[:0]const u8 = null,

pub fn open(io: std.Io, gpa: mem.Allocator, path: ?[:0]const u8) !*Self {
    const socket = try gpa.create(Self);
    errdefer gpa.destroy(socket);

    socket.* = try Self.init();
    errdefer socket.deinit(io, gpa);

    if (path) |p| {
        try socket.attempt(io, p);
    } else {
        try socket.attemptEmpty();
    }

    try socket.recheckPollFds(gpa);

    return socket;
}

fn init() !Self {
    var wake_pipes = try Io.Threaded.pipe2(.{ .CLOEXEC = true });
    var exit_pipes = try Io.Threaded.pipe2(.{ .CLOEXEC = true });

    return .{
        .wakeup_fd = Io.File{ .handle = wake_pipes[0] },
        .wakeup_write_fd = Io.File{ .handle = wake_pipes[1] },
        .exit_fd = Io.File{ .handle = exit_pipes[0] },
        .exit_write_fd = Io.File{ .handle = exit_pipes[1] },
    };
}

pub fn deinit(self: *Self, io: Io, gpa: mem.Allocator) void {
    for (self.clients.items) |client| {
        client.deinit(io, gpa);
        gpa.destroy(client);
    }
    self.clients.deinit(gpa);
    self.impls.deinit(gpa);
    if (self.poll_thread) |*thread| {
        self.thread_can_poll = false;

        {
            self.export_poll_mtx.lock();
            defer self.export_poll_mtx.unlock();
            self.poll_event = false;
            self.poll_event_cv.signal();
        }

        self.exit_write_fd.lock(io, .exclusive) catch {};
        defer self.exit_write_fd.unlock(io);
        var buffer: [1]u8 = undefined;
        var writer = self.exit_write_fd.writer(io, &buffer);
        var iowriter = &writer.interface;
        iowriter.writeAll("x") catch {};
        iowriter.flush() catch {};

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

pub fn addImplementation(self: *Self, gpa: mem.Allocator, impl: *const ProtocolImplementation) !void {
    try self.impls.append(gpa, impl);
}

pub fn dispatchPending(self: *Self, io: Io, gpa: mem.Allocator) !bool {
    if (self.pollfds.items.len == 0) return false;
    _ = try posix.poll(self.pollfds.items, 0);
    if (self.dispatchNewConnections(io, gpa))
        return self.dispatchPending(io, gpa);

    return self.dispatchExistingConnections(io, gpa);
}

pub fn dispatchEvents(self: *Self, io: Io, gpa: mem.Allocator, block: bool) !void {
    self.poll_mtx.lock();

    while (try self.dispatchPending(io, gpa)) {}

    try self.clearEventFd(io);
    try self.clearWakeupFd(io);

    if (block) {
        _ = try posix.poll(self.pollfds.items, -1);
        while (try self.dispatchPending(io, gpa)) {}
    }

    self.poll_mtx.unlock();

    {
        self.export_poll_mtx.lock();
        defer self.export_poll_mtx.unlock();
        self.poll_event = false;
        self.poll_event_cv.signal();
    }
}

fn clearFd(_: Io, fd: Io.File) void {
    var buf: [128]u8 = undefined;
    var fds = [_]posix.pollfd{.{ .fd = fd.handle, .events = posix.POLL.IN, .revents = 0 }};

    while (true) {
        _ = posix.poll(&fds, 0) catch break;

        if (fds[0].revents & posix.POLL.IN != 0) {
            const result = posix.system.read(fd.handle, &buf, buf.len);
            if (result <= 0) break;
            continue;
        }

        break;
    }
}

fn clearEventFd(self: *const Self, io: Io) !void {
    if (self.export_fd) |fd| {
        try fd.lock(io, .exclusive);
        defer fd.unlock(io);
        clearFd(io, fd);
    }
}

fn clearWakeupFd(self: *const Self, io: Io) !void {
    try self.wakeup_fd.lock(io, .exclusive);
    defer self.wakeup_fd.unlock(io);
    clearFd(io, self.wakeup_fd);
}

pub fn addClient(self: *Self, io: std.Io, gpa: mem.Allocator, file: Io.File) !*ServerClient {
    const stream = std.Io.net.Stream{ .socket = .{
        .handle = file.handle,
        .address = .{ .ip4 = .loopback(0) },
    } };
    const x = ServerClient{ .stream = stream };

    const client = try gpa.create(ServerClient);
    errdefer gpa.destroy(client);
    client.* = x;

    _ = posix.system.fcntl(file.handle, posix.F.GETFL, @as(u32, 0));

    client.self = client;
    client.server = self;
    try self.clients.append(gpa, client);
    errdefer _ = self.clients.pop();

    try self.recheckPollFds(gpa);

    try self.wakeup_write_fd.lock(io, .exclusive);
    defer self.wakeup_write_fd.unlock(io);
    var buffer: [1]u8 = undefined;
    var writer = self.wakeup_write_fd.writer(io, &buffer);
    var iowriter = &writer.interface;
    try iowriter.writeAll("x");
    try iowriter.flush();

    return client;
}

pub fn removeClient(self: *Self, io: Io, gpa: mem.Allocator, file: Io.File) bool {
    var removed: u32 = 0;

    var i: usize = self.clients.items.len;
    while (i > 0) {
        i -= 1;
        const client = self.clients.items[i];
        if (client.stream.socket.handle == file.handle) {
            var c = self.clients.swapRemove(i);
            c.deinit(io, gpa);
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
        .fd = self.exit_fd.handle,
        .events = posix.POLL.IN,
        .revents = 0,
    });

    try self.pollfds.append(gpa, .{
        .fd = self.wakeup_fd.handle,
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

pub fn dispatchNewConnections(self: *Self, io: Io, gpa: mem.Allocator) bool {
    var server = self.server orelse return false;

    if (self.is_empty_listener) return false;

    if ((self.pollfds.items[0].revents & posix.POLL.IN) == 0) return false;

    const stream = server.accept(io) catch return false;
    const x = gpa.create(ServerClient) catch {
        stream.close(io);
        return false;
    };
    x.* = .{ .stream = stream };
    x.server = self;
    x.self = x;

    self.clients.append(gpa, x) catch {
        gpa.destroy(x);
        return false;
    };

    self.recheckPollFds(gpa) catch return false;

    return true;
}

pub fn dispatchExistingConnections(self: *Self, io: Io, gpa: mem.Allocator) !bool {
    var had_any = false;
    var needs_poll_recheck = false;

    var i = self.internalFds();
    while (i < self.pollfds.items.len) : (i += 1) {
        if ((self.pollfds.items[i].revents & posix.POLL.IN) == 0) continue;

        try self.dispatchClient(io, gpa, self.clients.items[i - self.internalFds()]);

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
                c.deinit(io, gpa);
                gpa.destroy(c);
            }
        }
        try self.recheckPollFds(gpa);
    }

    return had_any;
}

pub fn dispatchClient(self: *Self, io: Io, gpa: mem.Allocator, client: *ServerClient) !void {
    _ = self;
    var data = SocketRawParsedMessage.readFromSocket(io, gpa, client.stream.socket) catch |err| {
        switch (err) {
            error.ConnectionResetByPeer => {
                client.@"error" = true;
                return;
            },
            else => return err,
        }
    };
    defer data.deinit(gpa);

    if (data.bad) {
        var buffer: [64]u8 = undefined;
        var fatal_msg = FatalError.initBuffer(&buffer, 0, 0, "fatal: invalid message on wire");
        client.sendMessage(io, gpa, &fatal_msg.interface);
        client.@"error" = true;
        return;
    }

    if (data.data.items.len == 0) return;

    message_parser.handleMessage(io, gpa, &data, .{ .server = client }) catch {
        var buffer: [64]u8 = undefined;
        var fatal_msg = FatalError.initBuffer(&buffer, 0, 0, "fatal: failed to handle message on wire");
        client.sendMessage(io, gpa, &fatal_msg.interface);
        client.@"error" = true;
        return;
    };

    if (client.scheduled_roundtrip_seq > 0) {
        var roundtrip_done = try RoundtripDone.init(gpa, client.scheduled_roundtrip_seq);
        defer roundtrip_done.deinit(gpa);
        client.sendMessage(io, gpa, &roundtrip_done.interface);
        client.scheduled_roundtrip_seq = 0;
    }
}

fn threadCallback(self: *Self, _: std.Io, gpa: mem.Allocator) void {
    while (self.thread_can_poll) {
        self.poll_mtx.lock();

        var pollfds = std.ArrayList(posix.pollfd).empty;
        defer pollfds.deinit(gpa);

        if (!self.is_empty_listener) {
            if (self.server) |server| {
                pollfds.append(gpa, .{
                    .fd = server.socket.handle,
                    .events = posix.POLL.IN,
                    .revents = 0,
                }) catch {
                    self.poll_mtx.unlock();
                    continue;
                };
            }
        }

        pollfds.append(gpa, .{
            .fd = self.exit_fd.handle,
            .events = posix.POLL.IN,
            .revents = 0,
        }) catch {
            self.poll_mtx.unlock();
            continue;
        };

        pollfds.append(gpa, .{
            .fd = self.wakeup_fd.handle,
            .events = posix.POLL.IN,
            .revents = 0,
        }) catch {
            self.poll_mtx.unlock();
            continue;
        };

        for (self.clients.items) |client| {
            pollfds.append(gpa, .{
                .fd = client.stream.socket.handle,
                .events = posix.POLL.IN,
                .revents = 0,
            }) catch {
                self.poll_mtx.unlock();
                continue;
            };
        }

        self.poll_mtx.unlock();

        if (pollfds.items.len == 0) continue;

        _ = posix.poll(pollfds.items, -1) catch continue;

        if (!self.thread_can_poll) return;

        {
            self.export_poll_mtx.lock();
            defer self.export_poll_mtx.unlock();

            self.poll_event = true;
            if (self.export_write_fd) |export_write_fd| {
                _ = posix.system.write(export_write_fd.handle, "x", 1);
            }

            while (self.poll_event and self.thread_can_poll) {
                self.poll_event_cv.timedWait(&self.export_poll_mtx, 100 * std.time.ns_per_ms) catch break;
            }
        }
    }
}

pub fn extractLoopFD(self: *Self, io: Io, gpa: mem.Allocator) !i32 {
    if (self.export_fd) |fd| {
        if (fd.length(io)) |_| {
            return fd.handle;
        } else |_| {}
    }

    var export_pipes = try Io.Threaded.pipe2(.{ .CLOEXEC = true });
    self.export_fd = Io.File{ .handle = export_pipes[0] };
    self.export_write_fd = Io.File{ .handle = export_pipes[1] };
    errdefer {
        if (self.export_fd) |*fd| fd.close(io);
        self.export_fd = null;
        if (self.export_write_fd) |*fd| fd.close(io);
        self.export_write_fd = null;
    }

    var exit_pipes = try Io.Threaded.pipe2(.{ .CLOEXEC = true });
    self.exit_fd = Io.File{ .handle = exit_pipes[0] };
    self.exit_write_fd = Io.File{ .handle = exit_pipes[1] };
    errdefer {
        self.exit_fd.close(io);
        self.exit_write_fd.close(io);
    }

    self.thread_can_poll = true;
    errdefer self.thread_can_poll = false;

    try self.recheckPollFds(gpa);

    self.poll_thread = try std.Thread.spawn(.{}, threadCallback, .{ self, io, gpa });

    const export_fd = self.export_fd orelse return error.NoEventFd;
    return export_fd.handle;
}

pub fn createObject(self: *Self, io: Io, gpa: mem.Allocator, client: ?*ServerClient, reference: ?*ServerObject, object: []const u8, seq: u32) ?*ServerObject {
    _ = self;
    if (client == null or reference == null) {
        return null;
    }

    if (reference) |ref| {
        if (client) |c| {
            const protocol_name = ref.protocol_name;
            const version = ref.version;

            return c.createObject(io, gpa, protocol_name, object, version, seq);
        }
    }

    return null;
}

test {
    std.testing.refAllDecls(@This());
}
