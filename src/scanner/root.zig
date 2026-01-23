const std = @import("std");
const Build = std.Build;

pub const Options = struct {};

b: *Build,
protocols: std.ArrayList(Build.LazyPath) = .empty,

const Self = @This();

pub fn init(b: *Build, options: Options) Self {
    _ = options;

    return .{
        .b = b,
    };
}

pub fn addCustomProtocol(self: *Self, path: Build.LazyPath) void {
    self.protocols.append(self.b.allocator, path) catch unreachable;
}

pub fn generate(self: *Self, interface: []const u8, version: u32) void {
    for (self.protocols.items) |protocol| {
        _ = protocol;
    }
    _ = interface;
    _ = version;
}
