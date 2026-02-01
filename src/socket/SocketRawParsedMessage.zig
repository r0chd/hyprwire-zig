const std = @import("std");
const c = @cImport(@cInclude("sys/socket.h"));
const helpers = @import("helpers");
const Io = std.Io;

const posix = std.posix;
const mem = std.mem;
const log = std.log.scoped(.hw);

data: std.ArrayList(u8) = .empty,
fds: std.ArrayList(i32) = .empty,
bad: bool = false,

const Self = @This();

pub fn readFromSocket(io: Io, gpa: mem.Allocator, socket: Io.net.Socket) !Self {
    const BUFFER_SIZE = 8192;
    const MAX_FDS_PER_MSG = 255;
    var buffer: [BUFFER_SIZE]u8 = undefined;
    var control_buf: [c.CMSG_SPACE(@sizeOf(i32) * MAX_FDS_PER_MSG)]u8 align(@alignOf(c.struct_cmsghdr)) = undefined;
    var fds = std.ArrayList(i32).empty;

    var incoming: Io.net.IncomingMessage = .{
        .from = undefined,
        .data = undefined,
        .control = &control_buf,
        .flags = undefined,
    };

    const err, const count = socket.receiveManyTimeout(io, @as(*[1]Io.net.IncomingMessage, &incoming), &buffer, .{}, .none);
    if (err) |e| return e;
    if (count == 0) return .{
        .bad = true,
    };

    var msghdr = c.msghdr{
        .msg_control = incoming.control.ptr,
        .msg_controllen = @intCast(incoming.control.len),
        .msg_name = null,
        .msg_namelen = 0,
        .msg_iov = undefined,
        .msg_iovlen = 0,
        .msg_flags = 0,
    };
    const recvd_cmsg = c.CMSG_FIRSTHDR(&msghdr);

    if (recvd_cmsg) |cmsg| {
        if (cmsg.*.cmsg_level != c.SOL_SOCKET or cmsg.*.cmsg_type != c.SCM_RIGHTS) {
            log.debug("protocol error: invalid control message type {}\n", .{cmsg.*.cmsg_type});
            return error.ProtocolError;
        }

        const data_ptr = helpers.CMSG_DATA(@ptrCast(cmsg));
        const fds_data: [*]i32 = @ptrCast(@alignCast(data_ptr));
        const payload_size = cmsg.*.cmsg_len - c.CMSG_LEN(0);
        const num_fds = payload_size / @sizeOf(i32);

        try fds.ensureTotalCapacity(gpa, num_fds);
        for (0..num_fds) |i| {
            const ptr = try fds.addOne(gpa);
            ptr.* = fds_data[i];
        }

        log.debug("SocketRawParsedMessage.readFromSocket: got {} fds on the control wire", .{num_fds});
    }

    return .{
        .data = std.ArrayList(u8).fromOwnedSlice(try gpa.dupe(u8, incoming.data)),
        .fds = fds,
    };
}

pub fn deinit(self: *Self, gpa: mem.Allocator) void {
    self.data.deinit(gpa);
    self.fds.deinit(gpa);
}

test "SocketRawParsedMessage.deinit empty" {
    const alloc = std.testing.allocator;

    var msg = Self{};
    msg.deinit(alloc);
}

test "SocketRawParsedMessage.fromFd receives payload and fd" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var sockets: [2]posix.socket_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &sockets));
    defer {
        for (sockets) |s| _ = posix.system.close(s);
    }

    var pipe_fds = try Io.Threaded.pipe2(.{});
    defer {
        for (pipe_fds) |fd| _ = posix.system.close(fd);
    }

    const payload = "hello";
    var iovec = c.iovec{
        .iov_base = @constCast(payload.ptr),
        .iov_len = payload.len,
    };

    var control_buf: [c.CMSG_SPACE(@sizeOf(i32))]u8 align(@alignOf(c.struct_cmsghdr)) = undefined;
    @memset(&control_buf, 0);

    var msg: c.msghdr = .{
        .msg_iov = &iovec,
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

    // TODO: https://codeberg.org/ziglang/zig/issues/30892
    const sent = c.sendmsg(sockets[0], &msg, 0);
    try std.testing.expect(sent == payload.len);

    const stream = std.Io.net.Stream{ .socket = .{
        .handle = sockets[1],
        .address = .{ .ip4 = .loopback(0) },
    } };

    var result = try Self.readFromSocket(io, alloc, stream.socket);
    defer result.deinit(alloc);

    try std.testing.expect(!result.bad);
    try std.testing.expectEqualStrings(payload, result.data.items);
    try std.testing.expect(result.fds.items.len == 1);

    for (result.fds.items) |fd| _ = posix.system.close(fd);
}
