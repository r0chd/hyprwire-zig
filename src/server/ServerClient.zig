const c = @cImport(@cInclude("sys/socket.h"));

const std = @import("std");
const root = @import("../root.zig");
const builtin = @import("builtin");
const types = @import("../implementation/types.zig");
const helpers = @import("helpers");
const messages = @import("../message/messages/root.zig");

const isTrace = helpers.isTrace;
const posix = std.posix;
const log = std.log.scoped(.hw);
const mem = std.mem;

const Message = messages.Message;
const WireObject = types.WireObject;
const ServerObject = @import("ServerObject.zig");
const ServerSocket = @import("ServerSocket.zig");
const Object = types.Object;

const Fd = helpers.Fd;
const steadyMillis = root.steadyMillis;

const Self = @This();

fd: Fd,
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
    var fd = Fd{ .raw = raw_fd };
    try fd.setFlags(posix.FD_CLOEXEC);

    return .{
        .fd = fd,
    };
}

pub fn deinit(self: *Self) void {
    if (isTrace()) {
        log.debug("[{}] destroying client", .{self.fd.raw});
    }
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

    posix.getsockopt(
        self.fd.raw,
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

pub fn sendMessage(self: *const Self, gpa: mem.Allocator, message: Message) void {
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
    if (fds.len != 0) {
        control_buf.resize(gpa, c.CMSG_SPACE(@sizeOf(i32) * fds.len)) catch |err| {
            log.debug("Failed to resize control buffer: {}", .{err});
            return;
        };
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

    _ = c.sendmsg(self.fd.raw, &msg, 0);
}

pub fn createObject(self: *Self, gpa: mem.Allocator, protocol: []const u8, object: []const u8, version: u32, seq: u32) ?*ServerObject {
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
            log.err("[{} @ {}] Error: createObject has no spec", .{ self.fd.raw, steadyMillis() });
            self.@"error" = true;
            return null;
        }

        if (protocol_spec.vtable.specVer(protocol_spec.ptr) < version) {
            log.err("[{} @ {}] Error: createObject for protocol {s} object {s} for version {}, but we have only {}", .{ self.fd.raw, steadyMillis(), protocol_name, object, version, protocol_spec.vtable.specVer(protocol_spec.ptr) });
            self.@"error" = true;
            return null;
        }

        break;
    }

    if (found_spec == null) {
        log.err("[{} @ {}] Error: createObject has no spec", .{ self.fd.raw, steadyMillis() });
        self.@"error" = true;
        return null;
    }

    obj.spec = found_spec;
    obj.protocol_name = gpa.dupe(u8, protocol_name) catch return null;
    errdefer gpa.free(obj.protocol_name);

    var ret = messages.NewObject.init(gpa, seq, obj.id) catch return null;
    defer ret.deinit(gpa);
    self.sendMessage(gpa, Message.from(&ret));

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

pub fn onGeneric(self: *Self, gpa: mem.Allocator, msg: messages.GenericProtocolMessage) !void {
    for (self.objects.items) |obj| {
        if (obj.id == msg.object) {
            try types.called(WireObject.from(obj), gpa, msg.method, msg.data_span, msg.fds_list);
            break;
        }
    }
}

pub fn getPid(self: *const Self) i32 {
    return self.pid;
}
