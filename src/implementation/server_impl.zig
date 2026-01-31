const std = @import("std");
const mem = std.mem;

const object = @import("object.zig");
const ProtocolSpec = @import("types.zig").ProtocolSpec;

pub const ObjectImplementation = struct {
    context: ?*anyopaque = null,
    object_name: []const u8 = "",
    version: u32 = 0,
    onBind: ?*const fn (*anyopaque, *object.Object) void = null,

    const Self = @This();
};

pub const ProtocolImplementation = struct {
    protocolFn: *const fn (*const Self) *const ProtocolSpec,
    implementationFn: *const fn (*const Self, mem.Allocator) anyerror![]*ObjectImplementation,

    const Self = @This();

    pub fn protocol(self: *const Self) *const ProtocolSpec {
        return self.protocolFn(self);
    }

    pub fn implementation(self: *const Self, gpa: mem.Allocator) ![]*ObjectImplementation {
        return self.implementationFn(self, gpa);
    }
};

test {
    std.testing.refAllDecls(@This());
}
