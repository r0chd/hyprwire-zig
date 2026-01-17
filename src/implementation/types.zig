const helpers = @import("helpers");
const Trait = helpers.trait.Trait;

pub const WireObject = @import("WireObject.zig").WireObject;
pub const Object = @import("Object.zig").Object;
pub const server_impl = @import("server_impl.zig");
pub const client_impl = @import("client_impl.zig");
pub const called = @import("WireObject.zig").called;

pub const Method = struct {
    idx: u32 = 0,
    params: []const u8,
    returns_type: []const u8 = "",
    since: u32 = 0,
};

pub const ProtocolObjectSpec = Trait(.{
    .objectName = fn () []const u8,
    .c2s = fn () []const Method,
    .s2c = fn () []const Method,
}, null);

pub const ProtocolSpec = Trait(.{
    .specName = fn () [:0]const u8,
    .specVer = fn () u32,
    .objects = fn () []const ProtocolObjectSpec,
}, null);
