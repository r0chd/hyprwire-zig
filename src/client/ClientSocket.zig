const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const posix = std.posix;
const fmt = std.fmt;

const helpers = @import("helpers");
const isTrace = helpers.isTrace;

const types = @import("../implementation/types.zig");
const Object = types.Object;
const WireObject = types.WireObject;
const ProtocolImplementation = types.client.ProtocolImplementation;
const ProtocolSpec = types.ProtocolSpec;
const message_parser = @import("../message/MessageParser.zig");
const Message = @import("../message/messages/Message.zig");
const steadyMillis = @import("../root.zig").steadyMillis;
const SocketRawParsedMessage = @import("../socket/SocketRawParsedMessage.zig");
const ClientObject = @import("ClientObject.zig");
const ServerSpec = @import("ServerSpec.zig");

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("errno.h");
});
const log = std.log.scoped(.hw);

const HANDSHAKE_MAX_MS: i64 = 5000;

stream: Io.net.Stream,
impls: std.ArrayList(*const ProtocolImplementation) = .empty,
server_specs: std.ArrayList(*ProtocolSpec) = .empty,
objects: std.ArrayList(*ClientObject) = .empty,
handshake_begin: std.time.Instant,
@"error": bool = false,
handshake_done: bool = false,
last_ackd_roundtrip_seq: u32 = 0,
last_sent_roundtrip_seq: u32 = 0,
seq: u32 = 0,

pending_socket_data: std.ArrayList(SocketRawParsedMessage) = .empty,
pending_outgoing: std.ArrayList(Message.GenericProtocolMessage) = .empty,
waiting_on_object: ?WireObject = null,

const Self = @This();

pub fn open(io: std.Io, gpa: mem.Allocator, source: union(enum) { file: Io.File, path: [:0]const u8 }) !*Self {
    const sock = try gpa.create(Self);
    errdefer gpa.destroy(sock);
    sock.* = .{
        .stream = undefined,
        .handshake_begin = try std.time.Instant.now(),
    };

    switch (source) {
        .file => |fd| try sock.attemptFromFile(io, gpa, fd),
        .path => |path| try sock.attempt(io, gpa, path),
    }

    return sock;
}

pub fn deinit(self: *Self, io: Io, gpa: mem.Allocator) void {
    self.impls.deinit(gpa);
    if (self.stream.socket.handle >= 0) {
        self.stream.close(io);
    }
    for (self.objects.items) |object| {
        gpa.destroy(object);
    }
    for (self.pending_socket_data.items) |*data| {
        data.deinit(gpa);
    }
    self.pending_socket_data.deinit(gpa);
    for (self.pending_outgoing.items) |*msg| {
        msg.deinit(gpa);
    }
    self.pending_outgoing.deinit(gpa);
    for (self.server_specs.items) |object| {
        object.deinit(gpa);
    }
    self.server_specs.deinit(gpa);
    self.objects.deinit(gpa);
    gpa.destroy(self);
}

pub fn attempt(self: *Self, io: std.Io, gpa: mem.Allocator, path: [:0]const u8) !void {
    var address = try Io.net.UnixAddress.init(path);
    self.stream = try address.connect(io);

    var message = Message.Hello.init();
    try self.sendMessage(io, gpa, &message.interface);
}

pub fn attemptFromFile(self: *Self, io: Io, gpa: mem.Allocator, file: Io.File) !void {
    self.stream = std.Io.net.Stream{ .socket = .{
        .handle = file.handle,
        .address = .{ .ip4 = .loopback(0) },
    } };

    var message = Message.Hello.init();
    try self.sendMessage(io, gpa, &message.interface);
}

pub fn addImplementation(self: *Self, gpa: mem.Allocator, impl: *const ProtocolImplementation) !void {
    try self.impls.append(gpa, impl);
}

pub fn waitForHandshake(self: *Self, io: Io, gpa: mem.Allocator) !void {
    self.handshake_begin = try std.time.Instant.now();

    while (!self.@"error" and !self.handshake_done) {
        try self.dispatchEvents(io, gpa, true);
    }

    if (self.@"error") {
        return error.TODO;
    }
}

pub fn isHandshakeDone(self: *const Self) bool {
    return self.handshake_done;
}

pub fn getSpec(self: *Self, name: []const u8) ?*ProtocolSpec {
    for (self.server_specs.items) |s| {
        if (mem.eql(u8, s.specName(), name)) return s;
    }

    return null;
}

pub fn onSeq(self: *Self, seq: u32, id: u32) void {
    for (self.objects.items) |object| {
        if (object.seq == seq) {
            object.id = id;
            return;
        }
    }

    log.debug("[{} @ {}] -> No object for sequence {} (Would be id {}).!", .{ self.stream.socket.handle, steadyMillis(), seq, id });
}

pub fn bindProtocol(
    self: *Self,
    io: Io,
    gpa: mem.Allocator,
    spec: *const ProtocolSpec,
    version: u32,
) !Object {
    if (version > spec.specVer()) {
        log.debug("version {} is larger than current spec ver of {}", .{ version, spec.specVer() });
        self.disconnectOnError(io);
        return error.VersionMismatch;
    }

    const object = try gpa.create(ClientObject);
    object.* = ClientObject.init(self);
    const objects = spec.objects();
    object.spec = objects[0];
    self.seq += 1;
    object.seq = self.seq;
    object.version = version;
    object.protocol_name = spec.specName();
    try self.objects.append(gpa, object);

    const spec_name = spec.specName();
    var bind_message = try Message.BindProtocol.init(gpa, spec_name, object.seq, version);
    defer bind_message.deinit(gpa);
    try self.sendMessage(io, gpa, &bind_message.interface);

    try self.waitForObject(io, gpa, .from(object));

    return .from(object);
}

pub fn makeObject(self: *Self, gpa: mem.Allocator, protocol_name: []const u8, object_name: []const u8, seq: u32) !*ClientObject {
    const object = try gpa.create(ClientObject);
    errdefer gpa.destroy(object);
    object.* = .init(self);
    object.protocol_name = protocol_name;

    for (self.impls.items) |impl| {
        var protocol = impl.protocol();
        if (!mem.eql(u8, protocol.specName(), protocol_name)) continue;

        for (protocol.objects()) |obj| {
            if (!mem.eql(u8, obj.objectName(), object_name)) continue;

            object.spec = obj;
            break;
        }
        break;
    }

    if (object.spec == null) {
        return error.NoSpec;
    }

    object.seq = seq;
    object.version = 0; // TODO: client version doesn't matter that much, but for verification's sake we could fix this
    try self.objects.append(gpa, object);
    return object;
}

pub fn waitForObject(self: *Self, io: Io, gpa: mem.Allocator, x: WireObject) !void {
    self.waiting_on_object = x;
    while (x.getId() == 0 and !self.@"error") {
        try self.dispatchEvents(io, gpa, true);
    }
    self.waiting_on_object = null;
}

pub fn dispatchEvents(self: *Self, io: Io, gpa: mem.Allocator, block: bool) !void {
    if (self.@"error") return error.ConnectionClosed;

    if (!self.handshake_done) {
        const now = try std.time.Instant.now();
        const elapsed_ns: i64 = @intCast(now.since(self.handshake_begin));

        const max_ms = @max(HANDSHAKE_MAX_MS - @divFloor(elapsed_ns, std.time.ns_per_ms), 0);

        var peek_buf: [1]u8 = undefined;
        var peek_msg: Io.net.IncomingMessage = .init;
        const err, const count = self.stream.socket.receiveManyTimeout(
            io,
            @as(*[1]Io.net.IncomingMessage, &peek_msg),
            &peek_buf,
            .{ .peek = true },
            .{ .duration = .{ .clock = .awake, .raw = if (block) .fromMilliseconds(max_ms) else .zero } },
        );
        if (err) |e| {
            switch (e) {
                error.Timeout => {
                    if (block) {
                        log.debug("handshake error: timed out", .{});
                        self.disconnectOnError(io);
                        return error.TimedOut;
                    }
                    return;
                },
                error.ConnectionResetByPeer => return error.ConnectionClosed,
                else => return e,
            }
        }

        // count == 0 when blocking means HUP
        if (count == 0) {
            if (block) return error.ConnectionClosed;
            return;
        }
    }

    if (self.handshake_done) {
        var peek_buf: [1]u8 = undefined;
        var peek_msg: Io.net.IncomingMessage = .init;
        const err, const count = self.stream.socket.receiveManyTimeout(
            io,
            @as(*[1]Io.net.IncomingMessage, &peek_msg),
            &peek_buf,
            .{ .peek = true },
            if (block) .none else .{ .duration = .{ .clock = .awake, .raw = .zero } },
        );
        if (err) |e| {
            if (e == error.ConnectionResetByPeer) return error.ConnectionClosed;
            return e;
        }

        // count == 0 when blocking means HUP
        if (count == 0) {
            if (block) return error.ConnectionClosed;
            return;
        }
    }

    // dispatch

    var data = try SocketRawParsedMessage.readFromSocket(io, gpa, self.stream.socket);
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

    message_parser.handleMessage(io, gpa, &data, .{ .client = self }) catch {
        log.debug("fatal: failed to handle message on wire", .{});
        self.disconnectOnError(io);
        return error.FailedToHandleMessage;
    };

    var i: usize = self.pending_outgoing.items.len;
    while (i > 0) {
        i -= 1;
        var msg = &self.pending_outgoing.items[i];
        const obj = self.objectForSeq(msg.depends_on_seq);
        if (obj == null) {
            var removed = self.pending_outgoing.orderedRemove(i);
            removed.deinit(gpa);
            continue;
        }

        if (obj.?.id == 0) {
            continue;
        }

        msg.resolveSeq(obj.?.id);
        if (isTrace()) {
            const d = try msg.interface.parseData(gpa);
            defer gpa.free(d);
            log.debug("[{} @ {}] -> Handle deferred {s}", .{ self.stream.socket.handle, steadyMillis(), d });
        }

        try self.sendMessage(io, gpa, &msg.interface);
        var removed = self.pending_outgoing.orderedRemove(i);
        removed.deinit(gpa);
    }

    if (self.@"error") {
        return error.ConnectionClosed;
    }
}

pub fn onGeneric(self: *const Self, io: Io, gpa: mem.Allocator, msg: Message.GenericProtocolMessage) !void {
    for (self.objects.items) |obj| {
        if (obj.id == msg.object) {
            try WireObject.from(obj).called(io, gpa, msg.method, msg.data_span, msg.fds);
            return;
        }
    }

    log.debug("[{} @ {}] -> Generic message not handled. No object with id {}!", .{ self.stream.socket.handle, steadyMillis(), msg.object });
}

pub fn objectForId(self: *const Self, id: u32) ?Object {
    for (self.objects.items) |object| {
        if (object.id == id) return Object.from(object);
    }

    return null;
}

pub fn objectForSeq(self: *const Self, seq: u32) ?*ClientObject {
    for (self.objects.items) |object| {
        if (object.seq == seq) return object;
    }

    return null;
}

pub fn sendMessage(self: *const Self, io: Io, gpa: mem.Allocator, message: *Message) !void {
    if (isTrace()) {
        if (message.parseData(gpa)) |parsed| {
            defer gpa.free(parsed);
            log.debug("[{} @ {}] -> {s}", .{ self.stream.socket.handle, steadyMillis(), parsed });
        } else |err| {
            log.debug("[{} @ {}] -> parse error: {}", .{ self.stream.socket.handle, steadyMillis(), err });
        }
    }

    var iovec: posix.iovec = std.mem.zeroes(posix.iovec);
    iovec.base = @constCast(message.data.ptr);
    iovec.len = message.len;

    var msg: c.msghdr = std.mem.zeroes(c.msghdr);
    msg.msg_iov = @ptrCast(&iovec);
    msg.msg_iovlen = 1;

    var control_buf: std.ArrayList(u8) = .empty;
    defer control_buf.deinit(gpa);
    const fds = message.getFds();
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

    while (self.stream.socket.handle >= 0) {
        // TODO: https://codeberg.org/ziglang/zig/issues/30892
        const ret = c.sendmsg(self.stream.socket.handle, &msg, 0);
        if (ret < 0) {
            const err = std.posix.errno(ret);

            if (err == .AGAIN) {
                var peek_buf: [1]u8 = undefined;
                var peek_msg: Io.net.IncomingMessage = .init;
                _, _ = self.stream.socket.receiveManyTimeout(
                    io,
                    @as(*[1]Io.net.IncomingMessage, &peek_msg),
                    &peek_buf,
                    .{ .peek = true },
                    .none,
                );
                continue;
            }
        }
        break;
    }
}

pub fn extractLoopFD(self: *const Self) i32 {
    return self.stream.socket.handle;
}

pub fn serverSpecs(self: *Self, io: Io, gpa: mem.Allocator, specs: []const []const u8) void {
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
        try self.server_specs.append(gpa, &s.interface);
    }
}

pub fn disconnectOnError(self: *Self, io: Io) void {
    self.@"error" = true;
    if (self.stream.socket.handle >= 0) {
        self.stream.close(io);
        self.stream.socket.handle = -1;
    }
}

pub fn roundtrip(self: *Self, io: Io, gpa: mem.Allocator) !void {
    if (self.@"error") return;

    self.last_sent_roundtrip_seq += 1;
    const next_seq = self.last_sent_roundtrip_seq;
    var message = try Message.RoundtripRequest.init(gpa, next_seq);
    defer message.deinit(gpa);
    try self.sendMessage(io, gpa, &message.interface);

    while (self.last_ackd_roundtrip_seq < next_seq) {
        self.dispatchEvents(io, gpa, true) catch break;
    }
}

test {
    std.testing.refAllDecls(@This());
}
