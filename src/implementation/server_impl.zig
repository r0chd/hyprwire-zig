const std = @import("std");
const mem = std.mem;

const Trait = @import("trait").Trait;

const Object = @import("Object.zig").Object;
const ProtocolSpec = @import("types.zig").ProtocolSpec;

pub const ObjectImplementation = struct {
    context: ?*anyopaque = null,
    object_name: []const u8 = "",
    version: u32 = 0,
    onBind: ?*const fn (*anyopaque, *Object) void = null,

    const Self = @This();
};

pub const ProtocolImplementation = Trait(.{
    .protocol = fn () ProtocolSpec,
    .implementation = fn (mem.Allocator) anyerror![]*ObjectImplementation,
}, null);

test {
    std.testing.refAllDecls(@This());
}
