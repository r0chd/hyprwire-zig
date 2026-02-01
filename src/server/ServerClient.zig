const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const Io = std.Io;

const helpers = @import("helpers");
const isTrace = helpers.isTrace;

const types = @import("../implementation/types.zig");
const Object = types.Object;
const WireObject = @import("../implementation/WireObject.zig");
const Message = @import("../message/messages/Message.zig");
const root = @import("../root.zig");
const steadyMillis = root.steadyMillis;
const ServerObject = @import("ServerObject.zig");
const ServerSocket = @import("ServerSocket.zig");

const c = @cImport(@cInclude("sys/socket.h"));

const log = std.log.scoped(.hw);
const Self = @This();

stream: Io.net.Stream,
pid: i32 = -1,
first_poll_done: bool = false,
version: u32 = 0,
max_id: u32 = 1,
@"error": bool = false,
scheduled_roundtrip_seq: u32 = 0,
objects: std.ArrayList(*ServerObject) = .empty,
server: ?*ServerSocket = null,
self: ?*Self = null,

pub fn deinit(self: *Self, io: Io, gpa: mem.Allocator) void {
    if (isTrace()) {
        log.debug("[{}] destroying client", .{self.stream.socket.handle});
    }
    for (self.objects.items) |object| {
        object.asObject().deinit(gpa);
        gpa.destroy(object);
    }
    self.objects.deinit(gpa);
    self.stream.close(io);
}

pub fn dispatchFirstPoll(self: *Self) void {
    if (self.first_poll_done) return;

    self.first_poll_done = true;

    var cred: extern struct {
        pid: std.c.pid_t,
        uid: std.c.uid_t,
        gid: std.c.gid_t,
    } = undefined;

    helpers.socket.getsockopt(
        self.stream.socket.handle,
        posix.SOL.SOCKET,
        posix.SO.PEERCRED,
        std.mem.asBytes(&cred),
    ) catch {
        if (isTrace()) {
            log.debug("dispatchFirstPoll: failed to get pid", .{});
        }
        return;
    };

    self.pid = cred.pid;
}

pub fn sendMessage(self: *const Self, io: Io, gpa: mem.Allocator, message: *Message) void {
    _ = io;
    if (isTrace()) {
        const parsed = message.parseData(gpa) catch |err| {
            log.debug("[{} @ {}] -> parse error: {}", .{ self.stream.socket.handle, steadyMillis(), err });
            return;
        };
        defer gpa.free(parsed);
        log.debug("[{} @ {}] -> {s}", .{ self.stream.socket.handle, steadyMillis(), parsed });
    }

    var iovec: posix.iovec = .{
        .base = @constCast(message.data.ptr),
        .len = message.len,
    };
    var msg: c.msghdr = .{
        .msg_iov = @ptrCast(&iovec),
        .msg_iovlen = 1,
        .msg_control = null,
        .msg_controllen = 0,
        .msg_flags = 0,
        .msg_name = null,
        .msg_namelen = 0,
    };

    var control_buf: std.ArrayList(u8) = .empty;
    const fds = message.getFds();
    if (fds.len != 0) {
        control_buf.resize(gpa, c.CMSG_SPACE(@sizeOf(i32) * fds.len)) catch return;
        msg.msg_controllen = control_buf.capacity;
        msg.msg_control = control_buf.items.ptr;

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
        const ret = c.sendmsg(self.stream.socket.handle, &msg, 0);
        if (ret < 0) {
            const err = std.posix.errno(ret);

            if (err == .AGAIN) {
                const pfd = posix.pollfd{
                    .fd = self.stream.socket.handle,
                    .events = posix.POLL.OUT,
                    .revents = 0,
                };
                var pfds = [_]posix.pollfd{pfd};

                _ = posix.poll(&pfds, -1) catch {};
                continue;
            }
        }
        break;
    }
}

pub fn createObject(
    self: *Self,
    io: Io,
    gpa: mem.Allocator,
    protocol: []const u8,
    object: []const u8,
    version: u32,
    seq: u32,
) ?*ServerObject {
    if (self.server == null) return null;

    const obj = gpa.create(ServerObject) catch return null;
    errdefer gpa.destroy(obj);
    obj.* = ServerObject.init(self);
    obj.id = self.max_id;
    self.max_id += 1;
    obj.version = version;
    self.objects.append(gpa, obj) catch return null;

    var found_spec: ?*const types.ProtocolObjectSpec = null;
    var protocol_name: []const u8 = "";

    for (self.server.?.impls.items) |impl| {
        const protocol_spec = impl.protocol();
        if (!mem.eql(u8, protocol_spec.specName(), protocol)) continue;

        for (protocol_spec.objects()) |spec| {
            if (object.len > 0 and !mem.eql(u8, spec.objectName(), object)) continue;
            found_spec = spec;
            break;
        }

        protocol_name = protocol_spec.specName();

        if (found_spec == null) {
            log.err("[{} @ {}] Error: createObject has no spec", .{ self.stream.socket.handle, steadyMillis() });
            self.@"error" = true;
            return null;
        }

        if (protocol_spec.specVer() < version) {
            log.err("[{} @ {}] Error: createObject for protocol {s} object {s} for version {}, but we have only {}", .{ self.stream.socket.handle, steadyMillis(), protocol_name, object, version, protocol_spec.specVer() });
            self.@"error" = true;
            return null;
        }

        break;
    }

    if (found_spec == null) {
        log.err("[{} @ {}] Error: createObject has no spec", .{ self.stream.socket.handle, steadyMillis() });
        self.@"error" = true;
        return null;
    }

    obj.spec = found_spec;
    obj.protocol_name = gpa.dupe(u8, protocol_name) catch return null;
    errdefer gpa.free(obj.protocol_name);

    var ret = Message.NewObject.init(gpa, seq, obj.id) catch return null;
    defer ret.deinit(gpa);
    self.sendMessage(io, gpa, &ret.interface);

    self.onBind(gpa, obj) catch return null;

    return obj;
}

pub fn onBind(self: *Self, gpa: mem.Allocator, obj: *ServerObject) !void {
    const server = self.server orelse return;
    for (server.impls.items) |impl| {
        const protocol = impl.protocol();
        if (!mem.eql(u8, protocol.specName(), obj.protocol_name)) continue;

        const implementations = try impl.implementation(gpa);
        defer {
            for (implementations) |implementation| {
                gpa.destroy(implementation);
            }
            gpa.free(implementations);
        }

        for (implementations) |implementation| {
            const spec = obj.spec orelse continue;
            if (!mem.eql(u8, implementation.object_name, spec.objectName())) continue;

            if (implementation.onBind) |on_bind| {
                const ctx = implementation.context orelse continue;
                const object = try gpa.create(Object);
                object.* = Object.from(obj);
                on_bind(ctx, object);
            }
            break;
        }

        break;
    }
}

pub fn onGeneric(self: *Self, io: Io, gpa: mem.Allocator, msg: Message.GenericProtocolMessage) (WireObject.Error || mem.Allocator.Error)!void {
    for (self.objects.items) |obj| {
        if (obj.id == msg.object) {
            try WireObject.from(obj).called(io, gpa, msg.method, msg.data_span, msg.fds);
            return;
        }
    }

    log.debug("[{} @ {}] -> Generic message not handled. No object with id {}!", .{ self.stream.socket.handle, steadyMillis(), msg.object });
}

pub fn getPid(self: *const Self) i32 {
    return self.pid;
}

test {
    std.testing.refAllDecls(@This());
}
