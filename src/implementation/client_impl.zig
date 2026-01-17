const std = @import("std");
const helpers = @import("helpers");
const Object = @import("Object.zig").Object;
const ProtocolSpec = @import("types.zig").ProtocolSpec;

const Trait = helpers.trait.Trait;
const mem = std.mem;

pub const ClientObjectImplementation = struct {
    object_name: []const u8 = "",
    version: u32 = 0,
};

pub const ProtocolClientImplementation = Trait(.{
    .protocol = fn () ProtocolSpec,
    .implementation = fn (mem.Allocator) anyerror![]*ClientObjectImplementation,
}, null);
