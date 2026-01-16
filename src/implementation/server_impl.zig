const std = @import("std");
const helpers = @import("helpers");
const Object = @import("Object.zig").Object;
const ProtocolSpec = @import("types.zig").ProtocolSpec;

const Trait = helpers.trait.Trait;
const mem = std.mem;

pub const ServerObjectImplementation = struct {
    object_name: []const u8 = "",
    version: u32 = 0,
    onBind: ?*const fn (object: Object) void = null,

    const Self = @This();
};

pub const ProtocolServerImplementation = Trait(.{
    .protocol = fn () ProtocolSpec,
    .implementation = fn (mem.Allocator) anyerror![]*ServerObjectImplementation,
}, null);
