const types = @import("../implementation/types.zig");
const ProtocolObjectSpec = types.ProtocolObjectSpec;
const ProtocolSpec = types.ProtocolSpec;
const std = @import("std");

name: []const u8,
version: u32,
interface: ProtocolSpec,

const Self = @This();

pub fn init(gpa: std.mem.Allocator, name: []const u8, version: u32) !*Self {
    const self = try gpa.create(Self);
    self.* = .{
        .name = try gpa.dupe(u8, name),
        .version = version,
        .interface = .{
            .deinitFn = Self.deinitFn,
            .objectsFn = Self.objectsFn,
            .specNameFn = Self.specNameFn,
            .specVerFn = Self.specVerFn,
        },
    };

    return self;
}

fn deinitFn(ptr: *const ProtocolSpec, gpa: std.mem.Allocator) void {
    const self: *const Self = @fieldParentPtr("interface", ptr);
    gpa.free(self.name);
    gpa.destroy(self);
}

pub fn specNameFn(ptr: *const ProtocolSpec) []const u8 {
    const self: *const Self = @fieldParentPtr("interface", ptr);
    return self.name;
}

pub fn specVerFn(ptr: *const ProtocolSpec) u32 {
    const self: *const Self = @fieldParentPtr("interface", ptr);
    return self.version;
}

pub fn objectsFn(ptr: *const ProtocolSpec) []const *const ProtocolObjectSpec {
    _ = ptr;
    return &.{};
}

test {
    std.testing.refAllDecls(@This());
}
