const std = @import("std");
const helpers = @import("helpers");
const Object = @import("Object.zig").Object;
const ProtocolSpec = @import("types.zig").ProtocolSpec;
const Trait = @import("trait").Trait;

const mem = std.mem;

pub const ServerObjectImplementation = struct {
    context: ?*anyopaque = null,
    object_name: []const u8 = "",
    version: u32 = 0,
    onBind: ?*const fn (*anyopaque, *Object) void = null,

    const Self = @This();
};

pub const ProtocolServerImplementation = Trait(.{
    .protocol = fn () ProtocolSpec,
    .implementation = fn (mem.Allocator) anyerror![]*ServerObjectImplementation,
}, null);
