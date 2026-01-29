// Generated with hyprwire-scanner 0.2.1. Made with pure malice and hatred by r0chd.
// test_protocol_v1

//
// This protocol's author copyright notice is:
// I eat paint
//

const std = @import("std");

const hyprwire = @import("hyprwire");
const types = hyprwire.types;

pub const MyEnum = enum(u32) {
   hello = 0,
   world = 4,
};

pub const MyErrorEnum = enum(u32) {
   oh_no = 0,
   error_important = 1,
};

pub const MyManagerV1Spec = struct {
    c2s_methods: []const types.Method = &.{
        .{
            .idx = 0,
            .params = &[_]u8{@intFromEnum(hyprwire.MessageMagic.type_varchar)},
            .returns_type = "",
            .since = 0,
        },
        .{
            .idx = 1,
            .params = &[_]u8{@intFromEnum(hyprwire.MessageMagic.type_fd)},
            .returns_type = "",
            .since = 0,
        },
        .{
            .idx = 2,
            .params = &[_]u8{@intFromEnum(hyprwire.MessageMagic.type_array), @intFromEnum(hyprwire.MessageMagic.type_varchar)},
            .returns_type = "",
            .since = 0,
        },
        .{
            .idx = 3,
            .params = &[_]u8{@intFromEnum(hyprwire.MessageMagic.type_array), @intFromEnum(hyprwire.MessageMagic.type_uint)},
            .returns_type = "",
            .since = 0,
        },
        .{
            .idx = 4,
            .params = &[_]u8{},
            .returns_type = "my_object_v1",
            .since = 0,
        },
    },

    s2c_methods: []const types.Method = &.{
        .{
            .idx = 0,
            .params = &[_]u8{@intFromEnum(hyprwire.MessageMagic.type_varchar)},
            .since = 0,
        },
        .{
            .idx = 1,
            .params = &[_]u8{@intFromEnum(hyprwire.MessageMagic.type_array), @intFromEnum(hyprwire.MessageMagic.type_uint)},
            .since = 0,
        },
    },

    const Self = @This();

    pub fn objectName(_: *const Self) []const u8 {
        return "my_manager_v1";
    }

    pub fn c2s(self: *const Self) []const types.Method {
        return self.c2s_methods;
    }

    pub fn s2c(self: *const Self) []const types.Method {
        return self.s2c_methods;
    }
};

pub const MyObjectV1Spec = struct {
    c2s_methods: []const types.Method = &.{
        .{
            .idx = 0,
            .params = &[_]u8{@intFromEnum(hyprwire.MessageMagic.type_varchar)},
            .returns_type = "",
            .since = 0,
        },
        .{
            .idx = 1,
            .params = &[_]u8{@intFromEnum(hyprwire.MessageMagic.type_uint)},
            .returns_type = "",
            .since = 0,
        },
        .{
            .idx = 2,
            .params = &[_]u8{},
            .returns_type = "",
            .since = 0,
        },
    },

    s2c_methods: []const types.Method = &.{
        .{
            .idx = 0,
            .params = &[_]u8{@intFromEnum(hyprwire.MessageMagic.type_varchar)},
            .since = 0,
        },
    },

    const Self = @This();

    pub fn objectName(_: *const Self) []const u8 {
        return "my_object_v1";
    }

    pub fn c2s(self: *const Self) []const types.Method {
        return self.c2s_methods;
    }

    pub fn s2c(self: *const Self) []const types.Method {
        return self.s2c_methods;
    }
};

pub const TestProtocolV1ProtocolSpec = struct {
    myManagerV1: MyManagerV1Spec = .{},
    myObjectV1: MyObjectV1Spec = .{},

    const Self = @This();

    pub fn specName(_: *const Self) []const u8 {
        return "test_protocol_v1";
    }

    pub fn specVer(_: *const Self) u32 {
        return 1;
    }

    pub fn objects(_: *const Self) []const types.ProtocolObjectSpec {
        return protocol_objects[0..];
    }

    pub fn deinit(_: *Self, _: std.mem.Allocator) void {}
};

pub const protocol = TestProtocolV1ProtocolSpec{};

pub const protocol_objects: [2]types.ProtocolObjectSpec = .{
    types.ProtocolObjectSpec.from(&protocol.myManagerV1),
    types.ProtocolObjectSpec.from(&protocol.myObjectV1),
};
