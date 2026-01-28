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

test {
    std.testing.refAllDecls(@This());
}
