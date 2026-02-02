const std = @import("std");
const mem = std.mem;

pub const client = @import("client_impl.zig");
pub const Object = @import("Object.zig");
pub const server = @import("server_impl.zig");
pub const WireObject = @import("WireObject.zig");

pub const MessageMagic = enum(u8) {
    /// Signifies an end of a message
    end = 0x0,

    /// Primitive type identifiers
    type_uint = 0x10,
    type_int = 0x11,
    type_f32 = 0x12,
    type_seq = 0x13,
    type_object_id = 0x14,

    /// Variable length types
    /// [magic : 1B][len : VLQ][data : len B]
    type_varchar = 0x20,

    /// [magic : 1B][type : 1B][n_els : VLQ]{ [data...] }
    type_array = 0x21,

    /// [magic : 1B][id : UINT][name_len : VLQ][object name ...]
    type_object = 0x22,

    /// Special types
    /// FD has size 0. It's passed via control.
    type_fd = 0x40,
};

pub const Method = struct {
    idx: u32 = 0,
    params: []const u8,
    returns_type: []const u8 = "",
    since: u32 = 0,
};

pub const ProtocolObjectSpec = struct {
    objectNameFn: *const fn (*const Self) []const u8,
    c2sFn: *const fn (*const Self) []const Method,
    s2cFn: *const fn (*const Self) []const Method,

    const Self = @This();

    pub fn objectName(self: *const Self) []const u8 {
        return self.objectNameFn(self);
    }

    pub fn c2s(self: *const Self) []const Method {
        return self.c2sFn(self);
    }

    pub fn s2c(self: *const Self) []const Method {
        return self.s2cFn(self);
    }
};

pub const ProtocolSpec = struct {
    specNameFn: *const fn (*const Self) []const u8,
    specVerFn: *const fn (*const Self) u32,
    objectsFn: *const fn (*const Self) []const *const ProtocolObjectSpec,
    deinitFn: *const fn (*Self, mem.Allocator) void,

    const Self = @This();

    pub fn specName(self: *const Self) []const u8 {
        return self.specNameFn(self);
    }

    pub fn specVer(self: *const Self) u32 {
        return self.specVerFn(self);
    }

    pub fn objects(self: *const Self) []const *const ProtocolObjectSpec {
        return self.objectsFn(self);
    }

    pub fn deinit(self: *Self, gpa: mem.Allocator) void {
        return self.deinitFn(self, gpa);
    }
};

test {
    std.testing.refAllDecls(@This());
}
