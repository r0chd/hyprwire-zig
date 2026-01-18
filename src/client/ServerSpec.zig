const ProtocolObjectSpec = @import("../implementation/types.zig").ProtocolObjectSpec;

name: []const u8,
version: u32,

const Self = @This();

pub fn init(name: []const u8, version: u32) Self {
    return .{
        .name = name,
        .version = version,
    };
}

pub fn specName(self: *const Self) []const u8 {
    return self.name;
}

pub fn specVer(self: *const Self) u32 {
    return self.version;
}

pub fn objects(self: *const Self) []const ProtocolObjectSpec {
    _ = self;
    return &.{};
}
