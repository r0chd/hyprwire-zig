const std = @import("std");
const c = @cImport(@cInclude("sys/socket.h"));

const posix = std.posix;
const mem = std.mem;

pub fn sunLen(addr: *const posix.sockaddr.un) usize {
    const path_ptr: [*:0]const u8 = @ptrCast(&addr.path);
    const path_len = mem.span(path_ptr).len;
    return @offsetOf(posix.sockaddr.un, "path") + path_len + 1;
}

pub fn CMSG_DATA(cmsg: *c.struct_cmsghdr) [*]u8 {
    const cmsg_bytes: [*]u8 = @ptrCast(cmsg);
    const header_size = c.CMSG_LEN(0);
    return cmsg_bytes + header_size;
}

pub const Fd = struct {
    raw: i32,

    const Self = @This();

    pub fn setFlags(self: *const Self, flags: u32) !void {
        if (!self.isValid() or self.isClosed()) return error.InvalidFd;

        _ = try posix.fcntl(self.raw, posix.F.SETFD, flags);
    }

    pub fn isClosed(self: *const Self) bool {
        if (!self.isValid()) return false;

        const raw_fd = self.raw;
        const pfd = posix.pollfd{
            .fd = raw_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        };

        var pollfd = [_]posix.pollfd{pfd};
        _ = posix.poll(&pollfd, 0) catch return true;

        return (pfd.revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0;
    }

    pub fn isValid(self: *const Self) bool {
        return self.raw != -1;
    }

    pub fn close(self: *Self) void {
        if (self.isValid()) {
            posix.close(self.raw);
            self.raw = -1;
        }
    }
};
