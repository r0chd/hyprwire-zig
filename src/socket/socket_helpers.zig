const std = @import("std");
const c = @cImport(@cInclude("sys/socket.h"));

const posix = std.posix;
const mem = std.mem;
const log = std.log.scoped(.hw);

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

    pub fn fromFd(gpa: mem.Allocator, fd: i32) !Self {
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

            var control_buf = try std.ArrayList(u8).initCapacity(gpa, MAX_FDS_PER_MSG * @sizeOf(i32));
            defer control_buf.deinit(gpa);
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

            try self.data.appendSlice(gpa, buffer[0..@intCast(size_written)]);

            // TODO: wait for zig api
            // https://codeberg.org/ziglang/zig/issues/30629
            const recvd_cmsg = c.CMSG_FIRSTHDR(&msg);
            if (recvd_cmsg) |cmsg| {
                if (cmsg.*.cmsg_level != c.SOL_SOCKET or cmsg.*.cmsg_type != c.SCM_RIGHTS) {
                    log.debug("protocol error on fd {}: invalid control message on wire of type {}\n", .{ fd, cmsg.*.cmsg_type });
                    return .{ .bad = true };
                }

                const data_ptr = CMSG_DATA(cmsg);
                const data: [*]i32 = @ptrCast(@alignCast(data_ptr));
                const payload_size = cmsg.*.cmsg_len - c.CMSG_LEN(0);
                const num_fds = payload_size / @sizeOf(i32);

                try self.fds.ensureTotalCapacity(gpa, self.fds.capacity + num_fds);

                for (0..num_fds) |i| {
                    const ptr = try self.fds.addOne(gpa);
                    ptr.* = data[i];
                }

                log.debug("SocketRawParsedMessage.fromFd: got {} fds on the control wire", .{num_fds});
            }

            if (size_written != BUFFER_SIZE) break;
        }

        return self;
    }

    pub fn deinit(self: *Self, gpa: mem.Allocator) void {
        self.data.deinit(gpa);
        self.fds.deinit(gpa);
    }
};

test "SocketRawParsedMessage.deinit empty" {
    const alloc = std.testing.allocator;

    var msg = SocketRawParsedMessage{};
    msg.deinit(alloc);
}

test "SocketRawParsedMessage.fromFd invalid fd" {
    const alloc = std.testing.allocator;

    const result = try SocketRawParsedMessage.fromFd(alloc, -1);
    try std.testing.expect(result.data.items.len == 0);
    try std.testing.expect(result.fds.items.len == 0);
    try std.testing.expect(!result.bad);
}

test "CMSG_DATA function" {
    var cmsg_buf: [c.CMSG_LEN(4)]u8 align(@alignOf(c.struct_cmsghdr)) = undefined;
    const cmsg: *c.struct_cmsghdr = @ptrCast(&cmsg_buf);

    cmsg.*.cmsg_len = c.CMSG_LEN(4);

    const data_ptr = CMSG_DATA(cmsg);
    const data_start: [*]u8 = @ptrCast(cmsg);
    const expected_offset = c.CMSG_LEN(0);

    try std.testing.expectEqual(data_start + expected_offset, data_ptr);
}
