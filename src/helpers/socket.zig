const std = @import("std");
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

test {
    std.testing.refAllDecls(@This());
}
