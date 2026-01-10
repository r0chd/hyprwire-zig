const std = @import("std");
const c = @cImport(@cInclude("sys/socket.h"));
const root = @import("../root.zig");

const posix = std.posix;
const log = std.log;
const mem = std.mem;

const ServerObject = @import("ServerObject.zig");
const ServerSocket = @import("ServerSocket.zig");
const Message = @import("../message/messages/Message.zig");

const steadyMillis = root.steadyMillis;

fn CMSG_DATA(cmsg: *c.struct_cmsghdr) [*]u8 {
    const cmsg_bytes: [*]u8 = @ptrCast(cmsg);
    const header_size = c.CMSG_LEN(0);
    return cmsg_bytes + header_size;
}

const Self = @This();

fd: i32,
pid: i32 = -1,
firstPollDone: bool = false,
version: u32 = 0,
max_id: u32 = 1,
err: bool = false,
scheduled_roundtrip_seq: u32 = 0,
objects: std.ArrayList(ServerObject) = .empty,
server: ?*ServerSocket = null,
self: ?*Self = null,

pub fn init(fd: i32) posix.FcntlError!Self {
    const flags = try posix.fcntl(fd, posix.F.GETFD, 0);
    _ = try posix.fcntl(fd, posix.F.SETFD, flags | posix.FD_CLOEXEC);
    return .{
        .fd = fd,
    };
}

pub fn sendMessage(self: *const Self, gpa: mem.Allocator, message: anytype) void {
    Message.CheckTrait(@TypeOf(message));

    const parsed = message.base.parseData(gpa) catch |err| {
        log.debug("[{} @ {}] -> parse error: {}", .{ self.fd, steadyMillis(), err });
        return;
    };
    defer gpa.free(parsed);
    log.debug("[{} @ {}] -> {s}", .{ self.fd, steadyMillis(), parsed });

    const fds = message.fds();

    var io: posix.iovec = .{
        .base = @constCast(message.base.data.ptr),
        .len = message.base.data.len,
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

        const data_ptr = CMSG_DATA(cmsg);
        const data: [*]i32 = @ptrCast(@alignCast(data_ptr));
        for (0..fds.len) |i| {
            data[i] = fds[i];
        }
    }

    _ = c.sendmsg(self.fd, &msg, 0);
}
