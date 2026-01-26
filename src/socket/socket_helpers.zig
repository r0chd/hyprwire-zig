const std = @import("std");
const c = @cImport(@cInclude("sys/socket.h"));
const helpers = @import("helpers");

const posix = std.posix;
const mem = std.mem;
const log = std.log.scoped(.hw);

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

            var control_buf: [c.CMSG_SPACE(@sizeOf(i32) * MAX_FDS_PER_MSG)]u8 align(@alignOf(c.struct_cmsghdr)) = undefined;
            var msg: c.msghdr = .{
                .msg_iov = @ptrCast(&io),
                .msg_iovlen = 1,
                .msg_control = &control_buf,
                .msg_controllen = @intCast(control_buf.len),
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

                const data_ptr = helpers.CMSG_DATA(@ptrCast(cmsg));
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

test "SocketRawParsedMessage.fromFd receives payload and fd" {
    const alloc = std.testing.allocator;

    var sockets: [2]posix.socket_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &sockets));
    defer for (sockets) |s| posix.close(s);

    var pipe_fds: [2]posix.fd_t = undefined;
    _ = posix.system.pipe(&pipe_fds);
    defer {
        for (pipe_fds) |fd| posix.close(fd);
    }

    const payload = "hello";
    var io = c.iovec{
        .iov_base = @constCast(payload.ptr),
        .iov_len = payload.len,
    };

    var control_buf: [c.CMSG_SPACE(@sizeOf(i32))]u8 align(@alignOf(c.struct_cmsghdr)) = undefined;
    @memset(&control_buf, 0);

    var msg: c.msghdr = .{
        .msg_iov = &io,
        .msg_iovlen = 1,
        .msg_control = &control_buf,
        .msg_controllen = control_buf.len,
        .msg_flags = 0,
        .msg_name = null,
        .msg_namelen = 0,
    };

    const cmsg_hdr: *c.struct_cmsghdr = @ptrCast(@alignCast(&control_buf));
    cmsg_hdr.*.cmsg_len = c.CMSG_LEN(@sizeOf(i32));
    cmsg_hdr.*.cmsg_level = c.SOL_SOCKET;
    cmsg_hdr.*.cmsg_type = c.SCM_RIGHTS;
    const data_ptr = helpers.CMSG_DATA(@ptrCast(cmsg_hdr));
    const fd_slice: [*]i32 = @ptrCast(@alignCast(data_ptr));
    fd_slice[0] = pipe_fds[1];

    const sent = c.sendmsg(sockets[0], &msg, 0);
    try std.testing.expect(sent == payload.len);

    var result = try SocketRawParsedMessage.fromFd(alloc, sockets[1]);
    defer result.deinit(alloc);

    try std.testing.expect(!result.bad);
    try std.testing.expectEqualStrings(payload, result.data.items);
    try std.testing.expect(result.fds.items.len == 1);

    for (result.fds.items) |fd| posix.close(fd);
}
