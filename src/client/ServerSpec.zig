const ProtocolObjectSpec = @import("../implementation/types.zig").ProtocolObjectSpec;
const std = @import("std");

name: []const u8,
version: u32,

const Self = @This();

pub fn init(gpa: std.mem.Allocator, name: []const u8, version: u32) !*Self {
    const self = try gpa.create(Self);
    self.* = .{
        .name = try gpa.dupe(u8, name),
        .version = version,
    };

    return self;
}

pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    gpa.free(self.name);
    gpa.destroy(self);
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

test {
    std.testing.refAllDecls(@This());
}
