const std = @import("std");
const mem = std.mem;

const ProtocolSpec = @import("types.zig").ProtocolSpec;

pub const ObjectImplementation = struct {
    object_name: []const u8 = "",
    version: u32 = 0,
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
