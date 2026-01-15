const c = @cImport(@cInclude("sys/socket.h"));

const std = @import("std");
const root = @import("../root.zig");
const builtin = @import("builtin");
const types = @import("../implementation/types.zig");
const helpers = @import("helpers");
const messages = @import("../message/messages/root.zig");

const posix = std.posix;
const log = std.log;
const mem = std.mem;

const Message = messages.Message;
const GenericProtocol = @import("../message/messages/GenericProtocolMessage.zig");
const ServerObject = @import("ServerObject.zig");
const ServerSocket = @import("ServerSocket.zig");

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
        return;
    };

    self.pid = cred.pid;
}

pub fn sendMessage(self: *const Self, gpa: mem.Allocator, message: Message) void {
    const parsed = messages.parseData(message, gpa) catch |err| {
        log.debug("[{} @ {}] -> parse error: {}", .{ self.fd.raw, steadyMillis(), err });
        return;
    };
    defer gpa.free(parsed);
    log.debug("[{} @ {}] -> {s}", .{ self.fd.raw, steadyMillis(), parsed });

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

pub fn createObject(self: *Self, gpa: mem.Allocator, protocol: []const u8, object: []const u8, version: u32, seq: u32) !?*ServerObject {
    if (self.server == null) return null;

    const obj = try gpa.create(ServerObject);
    errdefer gpa.destroy(obj);
    obj.* = ServerObject.init(self);
    obj.interface.id = self.max_id;
    self.max_id += 1;
    obj.interface.self = obj;
    obj.interface.version = version;
    try self.objects.append(gpa, obj);

    var found_spec: ?*const types.ProtocolObjectSpec = null;
    var protocol_name: []const u8 = "";

    for (self.server.?.impls.items) |impl| {
        const protocol_spec = impl.protocol();
        if (!mem.eql(u8, protocol_spec.specName(), protocol)) continue;

        for (protocol_spec.getObjects()) |spec| {
            if (object.len > 0 and !mem.eql(u8, spec.objectName(), object)) continue;
            found_spec = &spec;
            break;
        }

        protocol_name = protocol_spec.specName();

        if (found_spec == null) {
            log.err("[{} @ {}] Error: createObject has no spec", .{ self.fd.raw, steadyMillis() });
            self.@"error" = true;
            return null;
        }

        if (protocol_spec.specVer() < version) {
            log.err("[{} @ {}] Error: createObject for protocol {s} object {s} for version {}, but we have only {}", .{ self.fd.raw, steadyMillis(), protocol_name, object, version, protocol_spec.specVer() });
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

    obj.interface.spec = found_spec;
    obj.interface.protocol_name = try gpa.dupe(u8, protocol_name);
    errdefer gpa.free(obj.interface.protocol_name);

    var ret = messages.NewObject.init(seq, obj.interface.id);
    self.sendMessage(gpa, ret.message());

    self.onBind(obj);

    return obj;
}

pub fn onBind(self: *Self, obj: *ServerObject) void {
    if (self.server) |server| {
        for (server.impls.items) |impl| {
            if (!mem.eql(u8, impl.protocol().spec_name, obj.interface.protocol_name)) {
                continue;
            }

            for (impl.implementations) |implementation| {
                if (mem.eql(u8, implementation.object_name, obj.interface.spec.?.objectName())) {
                    continue;
                }

                if (implementation.on_bind) |on_bind| {
                    on_bind(obj);
                }
                break;
            }

            break;
        }
    }
}

pub fn onGeneric(self: *Self, gpa: mem.Allocator, msg: GenericProtocol) !void {
    for (self.objects.items) |obj| {
        if (obj.interface.id == msg.object) {
            try obj.called(gpa, msg.method, msg.data_span, msg.fds_list);
            break;
        }
    }
}

pub fn getPid(self: *const Self) i32 {
    return self.pid;
}
