const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const Io = std.Io;
const builtin = @import("builtin");

const helpers = @import("helpers");
const isTrace = helpers.isTrace;
const Fd = helpers.Fd;

const types = @import("../implementation/types.zig");
const WireObject = types.WireObject;
const Object = types.Object;
const messages = @import("../message/messages/root.zig");
const Message = messages.Message;
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

pub fn init(raw_fd: i32) !Self {
    const stream = std.Io.net.Stream{ .socket = .{
        .handle = raw_fd,
        .address = .{ .ip4 = .loopback(0) },
    } };

    return .{
        .stream = stream,
    };
}

pub fn deinit(self: *Self, gpa: mem.Allocator, io: Io) void {
    if (isTrace()) {
        log.debug("[{}] destroying client", .{self.stream.socket.handle});
    }
    for (self.objects.items) |object| {
        object.deinit(gpa);
        gpa.destroy(object);
    }
    self.objects.deinit(gpa);
    self.stream.close(io);
}

pub fn dispatchFirstPoll(self: *Self) void {
    if (self.first_poll_done) return;

    self.first_poll_done = true;

    const Credential = switch (builtin.os.tag) {
        .openbsd => extern struct {
            pid: std.c.pid_t,
            uid: std.c.uid_t,
            gid: std.c.gid_t,
        },
        else => extern struct {
            pid: std.c.pid_t,
            uid: std.c.uid_t,
            gid: std.c.gid_t,
        },
    };

    var cred: Credential = undefined;

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

pub fn sendMessage(self: *const Self, gpa: mem.Allocator, io: Io, message: Message) void {
    _ = io;
    if (isTrace()) {
        const parsed = messages.parseData(message, gpa) catch |err| {
            log.debug("[{} @ {}] -> parse error: {}", .{ self.stream.socket.handle, steadyMillis(), err });
            return;
        };
        defer gpa.free(parsed);
        log.debug("[{} @ {}] -> {s}", .{ self.stream.socket.handle, steadyMillis(), parsed });
    }

    var iovec: posix.iovec = .{
        .base = @constCast(message.vtable.getData(message.ptr).ptr),
        .len = message.vtable.getLen(message.ptr),
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
    const fds = message.vtable.getFds(message.ptr);
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

    _ = c.sendmsg(self.stream.socket.handle, &msg, 0);
}

pub fn createObject(
    self: *Self,
    gpa: mem.Allocator,
    io: Io,
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

    var found_spec: ?types.ProtocolObjectSpec = null;
    var protocol_name: []const u8 = "";

    for (self.server.?.impls.items) |impl| {
        const protocol_spec = impl.vtable.protocol(impl.ptr);
        if (!mem.eql(u8, protocol_spec.vtable.specName(protocol_spec.ptr), protocol)) continue;

        for (protocol_spec.vtable.objects(protocol_spec.ptr)) |spec| {
            if (object.len > 0 and !mem.eql(u8, spec.vtable.objectName(spec.ptr), object)) continue;
            found_spec = spec;
            break;
        }

        protocol_name = protocol_spec.vtable.specName(protocol_spec.ptr);

        if (found_spec == null) {
            log.err("[{} @ {}] Error: createObject has no spec", .{ self.stream.socket.handle, steadyMillis() });
            self.@"error" = true;
            return null;
        }

        if (protocol_spec.vtable.specVer(protocol_spec.ptr) < version) {
            log.err("[{} @ {}] Error: createObject for protocol {s} object {s} for version {}, but we have only {}", .{ self.stream.socket.handle, steadyMillis(), protocol_name, object, version, protocol_spec.vtable.specVer(protocol_spec.ptr) });
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

    var ret = messages.NewObject.init(gpa, seq, obj.id) catch return null;
    defer ret.deinit(gpa);
    self.sendMessage(gpa, io, Message.from(&ret));

    self.onBind(gpa, obj) catch return null;

    return obj;
}

pub fn onBind(self: *Self, gpa: mem.Allocator, obj: *ServerObject) !void {
    const server = self.server orelse return;
    for (server.impls.items) |impl| {
        const protocol = impl.vtable.protocol(impl.ptr);
        if (!mem.eql(u8, protocol.vtable.specName(protocol.ptr), obj.protocol_name)) continue;

        const implementations = try impl.vtable.implementation(impl.ptr, gpa);
        defer {
            for (implementations) |implementation| {
                gpa.destroy(implementation);
            }
            gpa.free(implementations);
        }

        for (implementations) |implementation| {
            const spec = obj.spec orelse continue;
            if (!mem.eql(u8, implementation.object_name, spec.vtable.objectName(spec.ptr))) continue;

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

pub fn onGeneric(self: *Self, gpa: mem.Allocator, io: Io, msg: messages.GenericProtocolMessage) !void {
    for (self.objects.items) |obj| {
        if (obj.id == msg.object) {
            try types.called(WireObject.from(obj), gpa, io, msg.method, msg.data_span, msg.fds_list);
            break;
        }
    }
}

pub fn getPid(self: *const Self) i32 {
    return self.pid;
}
