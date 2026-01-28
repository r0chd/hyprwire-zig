const std = @import("std");
const ProtocolSpec = @import("types.zig").ProtocolSpec;

const Trait = @import("trait").Trait;
const mem = std.mem;

pub const ObjectImplementation = struct {
    object_name: []const u8 = "",
    version: u32 = 0,
};

pub const ProtocolImplementation = Trait(.{
    .protocol = fn () ProtocolSpec,
    .implementation = fn (mem.Allocator) anyerror![]*ObjectImplementation,
}, null);

test {
    std.testing.refAllDecls(@This());
}
