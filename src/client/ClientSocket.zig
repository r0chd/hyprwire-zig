const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const posix = std.posix;
const fs = std.fs;
const fmt = std.fmt;

const helpers = @import("helpers");
const Fd = helpers.Fd;
const isTrace = helpers.isTrace;

const types = @import("../implementation/types.zig");
const Object = types.Object;
const WireObject = types.WireObject;
const ProtocolImplementation = types.client.ProtocolImplementation;
const ProtocolSpec = types.ProtocolSpec;
const message_parser = @import("../message/MessageParser.zig");
const messages = @import("../message/messages/root.zig");
const Message = messages.Message;
const steadyMillis = @import("../root.zig").steadyMillis;
const SocketRawParsedMessage = @import("../socket/socket_helpers.zig").SocketRawParsedMessage;
const ClientObject = @import("ClientObject.zig");
const ServerSpec = @import("ServerSpec.zig");

const c = @cImport(@cInclude("sys/socket.h"));
const log = std.log.scoped(.hw);
const HANDSHAKE_MAX_MS: i64 = 5000;

stream: Io.net.Stream,
impls: std.ArrayList(ProtocolImplementation) = .empty,
server_specs: std.ArrayList(ProtocolSpec) = .empty,
pollfds: std.ArrayList(posix.pollfd) = .empty,
objects: std.ArrayList(*ClientObject) = .empty,
handshake_begin: std.time.Instant,
@"error": bool = false,
handshake_done: bool = false,
last_ackd_roundtrip_seq: u32 = 0,
seq: u32 = 0,

pending_socket_data: std.ArrayList(SocketRawParsedMessage) = .empty,
waiting_on_object: ?*ClientObject = null,

const Self = @This();

pub fn open(gpa: mem.Allocator, io: std.Io, source: union(enum) { fd: i32, path: [:0]const u8 }) !*Self {
    const sock = try gpa.create(Self);
    errdefer gpa.destroy(sock);
    sock.* = .{
        .stream = undefined,
        .handshake_begin = try std.time.Instant.now(),
    };

    switch (source) {
        .fd => |fd| try sock.attemptFromFd(gpa, io, fd),
        .path => |path| try sock.attempt(gpa, io, path),
    }

    return sock;
}

pub fn deinit(self: *Self, gpa: mem.Allocator, io: Io) void {
    self.impls.deinit(gpa);
    self.pollfds.deinit(gpa);
    self.stream.close(io);
    for (self.objects.items) |object| {
        gpa.destroy(object);
    }
    for (self.pending_socket_data.items) |*data| {
        data.deinit(gpa);
    }
    self.pending_socket_data.deinit(gpa);
    for (self.server_specs.items) |object| {
        object.vtable.deinit(object.ptr, gpa);
    }
    self.server_specs.deinit(gpa);
    self.objects.deinit(gpa);
    gpa.destroy(self);
}

pub fn attempt(self: *Self, gpa: mem.Allocator, io: std.Io, path: [:0]const u8) !void {
    var address = try Io.net.UnixAddress.init(path);
    var stream = try address.connect(io);

    try self.pollfds.append(gpa, .{
        .fd = stream.socket.handle,
        .events = posix.POLL.IN,
        .revents = 0,
    });

    self.stream = stream;

    var message = messages.Hello.init();
    try self.sendMessage(gpa, io, Message.from(&message));
}

pub fn attemptFromFd(self: *Self, gpa: mem.Allocator, io: Io, raw_fd: i32) !void {
    const stream = std.Io.net.Stream{ .socket = .{
        .handle = raw_fd,
        .address = .{ .ip4 = .loopback(0) },
    } };

    try self.pollfds.append(gpa, .{
        .fd = raw_fd,
        .events = posix.POLL.IN,
        .revents = 0,
    });

    self.stream = stream;

    var message = messages.Hello.init();
    try self.sendMessage(gpa, io, Message.from(&message));
}

pub fn addImplementation(self: *Self, gpa: mem.Allocator, x: ProtocolImplementation) !void {
    try self.impls.append(gpa, x);
}

pub fn waitForHandshake(self: *Self, gpa: mem.Allocator, io: Io) !void {
    self.handshake_begin = try std.time.Instant.now();

    while (!self.@"error" and !self.handshake_done) {
        try self.dispatchEvents(gpa, io, true);
    }

    if (self.@"error") {
        return error.TODO;
    }
}

pub fn isHandshakeDone(self: *Self) bool {
    return self.handshake_done;
}

pub fn getSpec(self: *Self, name: []const u8) ?ProtocolSpec {
    for (self.server_specs.items) |s| {
        if (mem.eql(u8, s.vtable.specName(s.ptr), name)) return s;
    }

    return null;
}

pub fn onSeq(self: *Self, seq: u32, id: u32) void {
    for (self.objects.items) |object| {
        if (object.seq == seq) {
            object.id = id;
            break;
        }
    }
}

pub fn bindProtocol(self: *Self, gpa: mem.Allocator, io: Io, spec: ProtocolSpec, version: u32) !*ClientObject {
    if (version > spec.vtable.specVer(spec.ptr)) {
        log.debug("version {} is larger than current spec ver of {}", .{ version, spec.vtable.specVer(spec.ptr) });
        self.disconnectOnError(io);
        return error.VersionMismatch;
    }

    const object = try gpa.create(ClientObject);
    object.* = ClientObject.init(self);
    const objects = spec.vtable.objects(spec.ptr);
    object.spec = objects[0];
    self.seq += 1;
    object.seq = self.seq;
    object.version = version;
    object.protocol_name = spec.vtable.specName(spec.ptr);
    try self.objects.append(gpa, object);

    const spec_name = spec.vtable.specName(spec.ptr);
    var bind_message = try messages.BindProtocol.init(gpa, spec_name, object.seq, version);
    defer bind_message.deinit(gpa);
    try self.sendMessage(gpa, io, Message.from(&bind_message));

    try self.waitForObject(gpa, io, object);

    return object;
}

pub fn makeObject(self: *Self, gpa: mem.Allocator, protocol_name: []const u8, object_name: []const u8, seq: u32) ?*ClientObject {
    const object = gpa.create(ClientObject) catch return null;
    object.* = .init(self);
    object.protocol_name = protocol_name;

    for (self.impls.items) |impl| {
        var protocol = impl.vtable.protocol(impl.ptr);
        if (!mem.eql(u8, protocol.vtable.specName(protocol.ptr), protocol_name)) continue;

        for (protocol.vtable.objects(protocol.ptr)) |obj| {
            if (!mem.eql(u8, obj.vtable.objectName(obj.ptr), object_name)) continue;

            object.spec = obj;
            break;
        }
        break;
    }

    if (object.spec == null) {
        gpa.destroy(object);
        return null;
    }

    object.seq = seq;
    object.version = 0; // TODO: client version doesn't matter that much, but for verification's sake we could fix this
    self.objects.append(gpa, object) catch {
        gpa.destroy(object);
        return null;
    };
    return object;
}

pub fn waitForObject(self: *Self, gpa: mem.Allocator, io: Io, x: *ClientObject) !void {
    self.waiting_on_object = x;
    while (x.id == 0 and !self.@"error") {
        try self.dispatchEvents(gpa, io, true);
    }
    self.waiting_on_object = null;
}

pub fn shouldEndReading(self: *Self) bool {
    if (self.waiting_on_object) |waiting| {
        return waiting.id != 0;
    }

    return false;
}

pub fn dispatchEvents(self: *Self, gpa: mem.Allocator, io: Io, block: bool) !void {
    if (self.@"error") return error.ConnectionClosed;

    if (!self.handshake_done) {
        const now = try std.time.Instant.now();
        const elapsed_ns: i64 = @intCast(now.since(self.handshake_begin));

        const max_ms: i32 = @intCast(@max(HANDSHAKE_MAX_MS - @divFloor(elapsed_ns, std.time.ns_per_ms), 0));

        const ret = try posix.poll(self.pollfds.items, if (block) max_ms else 0);
        if (block and ret == 0) {
            log.debug("handshake error: timed out", .{});
            self.disconnectOnError(io);
            return error.TimedOut;
        }
    }

    if (self.pending_socket_data.items.len > 0) {
        const datas = try self.pending_socket_data.toOwnedSlice(gpa);
        self.pending_socket_data = .{}; // clear backing pointer to avoid reuse after freeing datas
        defer {
            for (datas) |*data| data.deinit(gpa);
            gpa.free(datas);
        }
        for (datas) |*data| {
            message_parser.handleMessage(gpa, io, data, .{ .client = self }) catch {
                log.debug("fatal: failed to handle message on wire", .{});
                self.disconnectOnError(io);
                return error.FailedToHandleMessage;
            };
        }
    }

    if (self.handshake_done) {
        _ = try posix.poll(self.pollfds.items, if (block) -1 else 0);
    }

    const revents = self.pollfds.items[0].revents;
    if ((revents & posix.POLL.HUP) != 0) {
        return error.ConnectionClosed;
    } else if (revents & posix.POLL.IN == 0) {
        return;
    }

    // dispatch

    var data = try SocketRawParsedMessage.fromFd(gpa, self.stream.socket.handle);
    defer data.deinit(gpa);
    if (data.bad) {
        log.debug("fatal: received malformed message from server", .{});
        self.disconnectOnError(io);
        return error.MessageMalformed;
    }

    if (data.data.items.len == 0) {
        self.disconnectOnError(io);
        return error.ConnectionClosed;
    }

    message_parser.handleMessage(gpa, io, &data, .{ .client = self }) catch {
        log.debug("fatal: failed to handle message on wire", .{});
        self.disconnectOnError(io);
        return error.FailedToHandleMessage;
    };

    if (self.@"error") {
        return error.ConnectionClosed;
    }
}

pub fn onGeneric(self: *Self, gpa: mem.Allocator, io: Io, msg: messages.GenericProtocolMessage) !void {
    for (self.objects.items) |obj| {
        if (obj.id == msg.object) {
            try types.called(
                WireObject.from(obj),
                gpa,
                io,
                msg.method,
                msg.data_span,
                msg.fds_list,
            );
            break;
        }
    }
}

pub fn objectForId(self: *Self, id: u32) ?Object {
    for (self.objects.items) |object| {
        if (object.id == id) return Object.from(object);
    }

    return null;
}

pub fn sendMessage(self: *Self, gpa: mem.Allocator, io: Io, message: Message) !void {
    _ = io;
    if (isTrace()) {
        const parsed = messages.parseData(message, gpa) catch |err| {
            log.debug("[{} @ {}] -> parse error: {}", .{ self.stream.socket.handle, steadyMillis(), err });
            return;
        };
        defer gpa.free(parsed);
        log.debug("[{} @ {}] -> {s}", .{ self.stream.socket.handle, steadyMillis(), parsed });
    }

    var iovec: posix.iovec = std.mem.zeroes(posix.iovec);
    iovec.base = @constCast(message.vtable.getData(message.ptr).ptr);
    iovec.len = message.vtable.getLen(message.ptr);

    var msg: c.msghdr = std.mem.zeroes(c.msghdr);
    msg.msg_iov = @ptrCast(&iovec);
    msg.msg_iovlen = 1;

    var control_buf: std.ArrayList(u8) = .empty;
    defer control_buf.deinit(gpa);
    const fds = message.vtable.getFds(message.ptr);
    if (fds.len > 0) {
        try control_buf.resize(gpa, c.CMSG_SPACE(@sizeOf(i32) * fds.len));
        @memset(control_buf.items, 0);

        msg.msg_control = control_buf.items.ptr;
        msg.msg_controllen = control_buf.items.len;

        const cmsg = c.CMSG_FIRSTHDR(&msg);
        cmsg.*.cmsg_level = c.SOL_SOCKET;
        cmsg.*.cmsg_type = c.SCM_RIGHTS;
        cmsg.*.cmsg_len = c.CMSG_LEN(@sizeOf(i32) * fds.len);

        const data_ptr = helpers.CMSG_DATA(@ptrCast(cmsg));
        const data: [*]i32 = @ptrCast(@alignCast(data_ptr));
        for (0..fds.len) |i| {
            data[i] = fds[i];
        }
    }

    _ = c.sendmsg(self.stream.socket.handle, &msg, 0);
}

pub fn extractLoopFD(self: *Self) i32 {
    return self.stream.socket.handle;
}

pub fn serverSpecs(self: *Self, gpa: mem.Allocator, io: Io, specs: []const []const u8) void {
    self.serverSpecsInner(gpa, specs) catch |err| {
        log.debug("fatal: failed to parse server specs: {}", .{err});
        self.disconnectOnError(io);
    };

    self.handshake_done = true;
}

fn serverSpecsInner(self: *Self, gpa: mem.Allocator, specs: []const []const u8) !void {
    for (specs) |spec| {
        const at_pos = mem.lastIndexOfScalar(u8, spec, '@') orelse return error.ParseError;

        const s = try ServerSpec.init(gpa, spec[0..at_pos], try fmt.parseInt(u32, spec[at_pos + 1 ..], 10));
        try self.server_specs.append(gpa, ProtocolSpec.from(s));
    }
}

pub fn disconnectOnError(self: *Self, io: Io) void {
    self.@"error" = true;
    self.stream.close(io);
}

pub fn roundtrip(self: *Self, gpa: mem.Allocator, io: Io) !void {
    if (self.@"error") return;

    const next_seq = self.last_ackd_roundtrip_seq + 1;
    var message = try messages.RoundtripRequest.init(gpa, next_seq);
    defer message.deinit(gpa);
    try self.sendMessage(gpa, io, Message.from(&message));

    while (self.last_ackd_roundtrip_seq < next_seq) {
        self.dispatchEvents(gpa, io, true) catch break;
    }
}
