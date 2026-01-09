const std = @import("std");
const c = @cImport(@cInclude("sys/socket.h"));
const rc = @import("../rc.zig");

const posix = std.posix;
const linux = std.os.linux;
const mem = std.mem;
const log = std.log;

fn CMSG_DATA(cmsg: *c.struct_cmsghdr) [*]u8 {
    const cmsg_bytes: [*]u8 = @ptrCast(cmsg);
    const header_size = c.CMSG_LEN(0);
    return cmsg_bytes + header_size;
}

pub const SocketRawParsedMessage = struct {
    data: std.ArrayList(u8) = .empty,
    fds: std.ArrayList(i32) = .empty,
    bad: bool = false,

    const Self = @This();

    pub fn fromFd(alloc: mem.Allocator, fd: i32) !Self {
        var self = Self{};
        const BUFFER_SIZE = 8192;
        const MAX_FDS_PER_MSG = 255;
        var buffer: [BUFFER_SIZE]u8 = undefined;

        var size_written: isize = 0;
        while (true) {
            var io: posix.iovec = .{
                .base = &buffer,
                .len = BUFFER_SIZE,
            };

            var control_buf = try std.ArrayList(u8).initCapacity(alloc, MAX_FDS_PER_MSG * @sizeOf(i32));
            defer control_buf.deinit(alloc);
            var msg: c.msghdr = .{
                .msg_iov = @ptrCast(&io),
                .msg_iovlen = 1,
                .msg_control = control_buf.items.ptr,
                .msg_controllen = @intCast(control_buf.capacity),
                .msg_flags = 0,
                .msg_name = null,
                .msg_namelen = 0,
            };

            size_written = c.recvmsg(fd, &msg, 0);
            if (size_written < 0) return .{};

            try self.data.appendSlice(alloc, &buffer);

            // TODO: wait for zig api
            // https://codeberg.org/ziglang/zig/issues/30629
            const recvd_cmsg = c.CMSG_FIRSTHDR(&msg);
            if (recvd_cmsg == null) continue;

            if (recvd_cmsg.*.cmsg_level != c.SOL_SOCKET or recvd_cmsg != c.SCM_RIGHTS) {
                log.debug("protocol error on fd {}: invalid control message on wire of type {}\n", .{ fd, recvd_cmsg.*.cmsg_type });
                return .{ .bad = true };
            }

            if (size_written != BUFFER_SIZE) break;
            const data_ptr = CMSG_DATA(recvd_cmsg);
            const data: [*]i32 = @ptrCast(@alignCast(data_ptr));
            const payload_size = recvd_cmsg.*.cmsg_len - c.CMSG_LEN(0);
            const num_fds = payload_size / @sizeOf(i32);

            try self.fds.ensureTotalCapacity(alloc, self.fds.capacity + num_fds);

            for (0..num_fds) |i| {
                const ptr = try self.fds.addOne(alloc);
                ptr.* = data[i];
            }

            log.debug("parseFromFd: got {} fds on the control wire", .{num_fds});
        }

        return self;
    }

    pub fn deinit(self: *Self, alloc: mem.Allocator) void {
        self.data.deinit(alloc);
        self.fds.deinit(alloc);
    }
};
