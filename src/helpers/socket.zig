const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const GetSockOptError = error{
    /// The calling process does not have the appropriate privileges.
    AccessDenied,

    /// The option is not supported by the protocol.
    InvalidProtocolOption,

    /// Insufficient resources are available in the system to complete the call.
    SystemResources,
} || posix.UnexpectedError;

pub fn getsockopt(fd: posix.socket_t, level: i32, optname: u32, opt: []u8) GetSockOptError!void {
    var len: posix.socklen_t = @intCast(opt.len);
    switch (posix.errno(posix.system.getsockopt(fd, level, optname, opt.ptr, &len))) {
        .SUCCESS => {
            std.debug.assert(len == opt.len);
        },
        .BADF => unreachable,
        .NOTSOCK => unreachable,
        .INVAL => unreachable,
        .FAULT => unreachable,
        .NOPROTOOPT => return error.InvalidProtocolOption,
        .NOMEM => return error.SystemResources,
        .NOBUFS => return error.SystemResources,
        .ACCES => return error.AccessDenied,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn getsockoptError(sockfd: posix.fd_t) posix.ConnectError!void {
    var err_code: i32 = undefined;
    var size: u32 = @sizeOf(u32);
    const rc = posix.system.getsockopt(sockfd, posix.SOL.SOCKET, posix.SO.ERROR, @ptrCast(&err_code), &size);
    std.debug.assert(size == 4);
    switch (posix.errno(rc)) {
        .SUCCESS => switch (@as(posix.system.E, @enumFromInt(err_code))) {
            .SUCCESS => return,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .ADDRINUSE => return error.AddressInUse,
            .ADDRNOTAVAIL => return error.AddressUnavailable,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .AGAIN => return error.SystemResources,
            .ALREADY => return error.ConnectionPending,
            .BADF => unreachable, // sockfd is not a valid open file descriptor.
            .CONNREFUSED => return error.ConnectionRefused,
            .FAULT => unreachable, // The socket structure address is outside the user's address space.
            .ISCONN => return error.AlreadyConnected, // The socket is already connected.
            .HOSTUNREACH => return error.NetworkUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
            .PROTOTYPE => unreachable, // The socket type does not support the requested communications protocol.
            .TIMEDOUT => return error.Timeout,
            .CONNRESET => return error.ConnectionResetByPeer,
            else => |err| return posix.unexpectedErrno(err),
        },
        .BADF => unreachable, // The argument sockfd is not a valid file descriptor.
        .FAULT => unreachable, // The address pointed to by optval or optlen is not in a valid part of the process address space.
        .INVAL => unreachable,
        .NOPROTOOPT => unreachable, // The option is unknown at the level indicated.
        .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub fn bind(sock: posix.socket_t, addr: *const posix.sockaddr, len: posix.socklen_t) !void {
    switch (posix.errno(posix.system.bind(sock, addr, len))) {
        .SUCCESS => return,
        else => return error.BindFailure,
    }
}

pub fn listen(sock: posix.socket_t, backlog: u31) !void {
    switch (posix.errno(posix.system.listen(sock, backlog))) {
        .SUCCESS => return,
        else => return error.ListenFailure,
    }
}

pub const AcceptError = std.Io.net.Server.AcceptError;

pub fn accept(
    sock: posix.socket_t,
    addr: ?*posix.sockaddr,
    addr_size: ?*posix.socklen_t,
    flags: u32,
) AcceptError!posix.socket_t {
    const have_accept4 = !(builtin.target.os.tag.isDarwin() or builtin.os.tag == .windows or builtin.os.tag == .haiku);
    std.debug.assert(0 == (flags & ~@as(u32, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC))); // Unsupported flag(s)

    const accepted_sock: posix.socket_t = while (true) {
        const rc = if (have_accept4)
            posix.system.accept4(sock, addr, addr_size, flags)
        else
            posix.system.accept(sock, addr, addr_size);

        if (builtin.os.tag == .windows) {
            @compileError("use std.Io instead");
        } else {
            switch (posix.errno(rc)) {
                .SUCCESS => break @intCast(rc),
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .BADF => unreachable, // always a race condition
                .CONNABORTED => return error.ConnectionAborted,
                .FAULT => unreachable,
                .INVAL => return error.SocketNotListening,
                .NOTSOCK => unreachable,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOBUFS => return error.SystemResources,
                .NOMEM => return error.SystemResources,
                .OPNOTSUPP => unreachable,
                .PROTO => return error.ProtocolFailure,
                .PERM => return error.BlockedByFirewall,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    };

    errdefer switch (builtin.os.tag) {
        .windows => std.os.windows.closesocket(accepted_sock) catch unreachable,
        else => posix.close(accepted_sock),
    };
    if (!have_accept4) {
        try posix.setSockFlags(accepted_sock, flags);
    }
    return accepted_sock;
}
