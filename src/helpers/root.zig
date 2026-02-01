const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const Io = std.Io;

const MessageMagic = @import("hyprwire").MessageMagic;

pub const FallbackAllocator = @import("FallbackAllocator.zig");
pub const socket = @import("socket.zig");
pub const Trait = @import("trait.zig").Trait;

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("ffi.h");
});

pub fn isTrace() bool {
    // Holy moly I'm not going to ask user to pass
    // Environ.Map everytime I need to know if tracing
    // is enabled, that would be insane lmfao
    const trace = std.c.getenv("HW_TRACE") orelse return false;
    return mem.eql(u8, "1", mem.span(trace)) or mem.eql(u8, "true", mem.span(trace));
}

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

pub fn ffiTypeFrom(magic: MessageMagic) *c.ffi_type {
    return switch (magic) {
        .type_uint, .type_object, .type_seq => &c.ffi_type_uint32,
        .type_fd, .type_int => &c.ffi_type_sint32,
        .type_f32 => &c.ffi_type_float,
        .type_varchar, .type_array => &c.ffi_type_pointer,
        else => unreachable,
    };
}

test {
    std.testing.refAllDecls(@This());
}
