const std = @import("std");
const types = @import("../implementation/types.zig");
const helpers = @import("helpers");
const message_parser = @import("../message/MessageParser.zig");
const c = @cImport(@cInclude("sys/socket.h"));

const messages = @import("../message/messages/root.zig");
const Message = messages.Message;
const Object = types.Object;
const WireObject = types.WireObject;
const SocketRawParsedMessage = @import("../socket/socket_helpers.zig").SocketRawParsedMessage;
const GenericProtocolMessage = messages.GenericProtocolMessage;

const isTrace = helpers.isTrace;
const mem = std.mem;
const posix = std.posix;
const log = std.log;
const fs = std.fs;

const ClientObject = @import("ClientObject.zig");

const ProtocolClientImplementation = types.client_impl.ProtocolClientImplementation;
const ProtocolSpec = types.ProtocolSpec;
const Fd = helpers.Fd;

const steadyMillis = @import("../root.zig").steadyMillis;

const HANDSHAKE_MAX_MS: i64 = 5000;

fd: Fd,
impls: std.ArrayList(ProtocolClientImplementation) = .empty,
server_specs: std.ArrayList(ProtocolSpec) = .empty,
pollfds: std.ArrayList(posix.pollfd) = .empty,
objects: std.ArrayList(ClientObject) = .empty,
handshake_begin: std.time.Instant,
@"error": bool = false,
handshake_done: bool = false,
last_ackd_roundtrip_seq: u32 = 0,
seq: u32 = 0,

pending_socket_data: std.ArrayList(SocketRawParsedMessage) = .empty,
waiting_on_object: ?*ClientObject = null,

const Self = @This();

pub fn open(gpa: mem.Allocator, source: union(enum) { fd: i32, path: [:0]const u8 }) !*Self {
    const sock = try gpa.create(Self);
    errdefer gpa.destroy(sock);
    sock.* = .{
        .fd = undefined,
        .handshake_begin = try std.time.Instant.now(),
    };

    switch (source) {
        .fd => |fd| try sock.attemptFromFd(gpa, fd),
        .path => |path| try sock.attempt(gpa, path),
    }

    return sock;
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    self.impls.deinit(gpa);
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

    var message = messages.Hello.init();
    try self.sendMessage(gpa, Message.from(&message));
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

    var message = messages.Hello.init();
    try self.sendMessage(gpa, Message.from(&message));
}

pub fn addImplementation(self: *Self, gpa: mem.Allocator, x: ProtocolClientImplementation) !void {
    try self.impls.append(gpa, x);
}

pub fn waitForHandshake(self: *Self, gpa: mem.Allocator) !void {
    self.handshake_begin = try std.time.Instant.now();

    while (!self.@"error" and !self.handshake_done) {
        try self.dispatchEvents(gpa, true);
    }

    return error.TODO;
}

pub fn isHandshakeDone(self: *Self) bool {
    return self.handshake_done;
}

pub fn getSpec(self: *Self, name: [:0]const u8) ?ProtocolSpec {
    for (self.server_specs.items) |s| {
        if (mem.eql(u8, s.vtable.specName(s.ptr), name)) return s;
    }

    return null;
}

pub fn onSeq(self: *Self, seq: u32, id: u32) void {
    for (self.objects.items) |*object| {
        if (object.seq == seq) {
            object.id = id;
            break;
        }
    }
}

pub fn bindProtocol(self: *Self, gpa: mem.Allocator, spec: ProtocolSpec, version: u32) !Object {
    if (version > spec.vtable.specVer(spec.ptr)) {
        log.debug("version {} is larger than current spec ver of {}", .{ version, spec.vtable.specVer(spec.ptr) });
        self.disconnectOnError();
        return error.VersionMismatch;
    }

    var object = ClientObject.init(self);
    const objects = spec.vtable.objects(spec.ptr);
    object.spec = objects[objects.len - 1];
    self.seq += 1;
    object.seq = self.seq;
    object.version = version;
    object.protocol_name = spec.vtable.specName(spec.ptr);
    try self.objects.append(gpa, object);

    const bind_message = try messages.BindProtocol.init(gpa, spec.vtable.specName(spec.ptr), object.seq, version);
    try self.sendMessage(gpa, Message.from(&bind_message));

    try self.waitForObject(gpa, &object);

    return Object.from(&self.objects.getLast());
}

pub fn makeObject(self: *Self, gpa: mem.Allocator, protocol_name: [:0]const u8, object_name: [:0]const u8, seq: u32) ?*ClientObject {
    var object = ClientObject.init(self);
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
        return null;
    }

    object.seq = seq;
    object.version = 0; // TODO: client version doesn't matter that much, but for verification's sake we could fix this
    self.objects.append(gpa, object);
    return object;
}

pub fn waitForObject(self: *Self, gpa: mem.Allocator, x: *ClientObject) !void {
    self.waiting_on_object = x;
    while (x.id == 0 and !self.@"error") {
        try self.dispatchEvents(gpa, true);
    }
    self.waiting_on_object = null;
}

pub fn shouldEndReading(self: *Self) bool {
    if (self.waiting_on_object) |waiting| {
        return waiting.id != 0;
    }

    return false;
}

pub fn dispatchEvents(self: *Self, gpa: mem.Allocator, block: bool) !void {
    if (self.@"error") return error.TODO;

    if (!self.handshake_done) {
        const now = try std.time.Instant.now();
        const elapsed_ns: i64 = @intCast(now.since(self.handshake_begin));

        const max_ms: i32 = @intCast(@max(HANDSHAKE_MAX_MS - @divFloor(elapsed_ns, std.time.ns_per_ms), 0));

        const ret = try posix.poll(self.pollfds.items, if (block) max_ms else 0);
        if (block and ret == 0) {
            log.debug("handshake error: timed out", .{});
            self.disconnectOnError();
            return error.TimedOut;
        }
    }

    if (self.pending_socket_data.items.len > 0) {
        const datas = try self.pending_socket_data.toOwnedSlice(gpa);
        for (datas) |*data| {
            const ret = message_parser.message_parser.handleMessage(gpa, data, .{ .client = self });
            if (ret != .ok) {
                log.debug("fatal: failed to handle message on wire", .{});
                self.disconnectOnError();
                return error.FailedToHandleMessage;
            }
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

    var data = try SocketRawParsedMessage.fromFd(gpa, self.fd.raw);
    if (data.bad) {
        log.debug("fatal: received malformed message from server", .{});
        self.disconnectOnError();
        return error.MessageMalformed;
    }

    if (data.data.items.len == 0) return error.NoData;

    const ret = message_parser.message_parser.handleMessage(gpa, &data, .{
        .client = self,
    });

    if (ret != .ok) {
        log.debug("fatal: failed to handle message on wire", .{});
        self.disconnectOnError();
        // make handleMessage return an error instead of enum
        return error.TODO;
    }

    if (self.@"error") {
        return error.TODO;
    }
}

pub fn onGeneric(self: *Self, gpa: mem.Allocator, msg: messages.GenericProtocolMessage) !void {
    for (self.objects.items) |obj| {
        if (obj.id == msg.object) {
            try types.called(WireObject.from(&obj), gpa, msg.method, msg.data_span, msg.fds_list);
            break;
        }
    }
}

pub fn objectForId(self: *Self, id: u32) ?Object {
    for (self.objects.items) |*object| {
        if (object.id == id) return Object.from(object);
    }

    return null;
}

pub fn sendMessage(self: *Self, gpa: mem.Allocator, message: Message) !void {
    if (isTrace()) {
        const parsed = messages.parseData(message, gpa) catch |err| {
            log.debug("[{} @ {}] -> parse error: {}", .{ self.fd.raw, steadyMillis(), err });
            return;
        };
        defer gpa.free(parsed);
        log.debug("[{} @ {}] -> {s}", .{ self.fd.raw, steadyMillis(), parsed });
    }

    var io: posix.iovec = .{
        .base = @constCast(message.vtable.getData(message.ptr).ptr),
        .len = message.vtable.getLen(message.ptr),
    };
    var msg: c.msghdr = .{
        .msg_iov = @ptrCast(&io),
        .msg_iovlen = 1,
        .msg_control = null,
        .msg_controllen = 0,
        .msg_flags = 0,
        .msg_name = null,
        .msg_namelen = 0,
    };

    var control_buf: std.ArrayList(u8) = .empty;
    const fds = message.vtable.getFds(message.ptr);
    if (fds.len > 0) {
        try control_buf.resize(gpa, c.CMSG_LEN(@sizeOf(i32) * fds.len));

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

    _ = c.sendmsg(self.fd.raw, &msg, 0);
}

pub fn disconnectOnError(self: *Self) void {
    self.@"error" = true;
    self.fd.close();
}

pub fn roundtrip(self: *Self, gpa: mem.Allocator) !void {
    if (self.@"error") return;

    const next_seq = self.last_ackd_roundtrip_seq + 1;
    var message = messages.RoundtripRequest.init(next_seq);
    try self.sendMessage(gpa, Message.from(&message));

    while (self.last_ackd_roundtrip_seq < next_seq) {
        try self.dispatchEvents(gpa, true);
    }
}
