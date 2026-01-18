const types = @import("hyprwire").types;
const MessageMagic = @import("hyprwire").MessageMagic;

const Method = types.Method;
const ProtocolSpec = types.ProtocolSpec;
const ProtocolObjectSpec = types.ProtocolObjectSpec;

pub const TestProtocolV1MyEnum = enum(u32) {
    hello = 0,
    world = 4,
};

pub const TestProtocolV1MyErrorEnum = enum(u32) {
    oh_no = 0,
    error_important = 1,
};

pub const MyManagerV1Spec = struct {
    c2s_methods: []const Method = &.{
        .{
            .idx = 0,
            .params = &[_]u8{@intFromEnum(MessageMagic.type_varchar)},
            .returns_type = "",
            .since = 0,
        },
        .{
            .idx = 1,
            .params = &[_]u8{},
            .returns_type = "",
            .since = 0,
        },
        .{
            .idx = 2,
            .params = &[_]u8{ @intFromEnum(MessageMagic.type_array), @intFromEnum(MessageMagic.type_varchar) },
            .returns_type = "",
            .since = 0,
        },
        .{
            .idx = 3,
            .params = &[_]u8{ @intFromEnum(MessageMagic.type_array), @intFromEnum(MessageMagic.type_uint) },
            .returns_type = "",
            .since = 0,
        },
        .{
            .idx = 4,
            .params = &[_]u8{@intFromEnum(MessageMagic.type_varchar)},
            .returns_type = "my_object_v1",
            .since = 0,
        },
    },

    s2c_methods: []const Method = &.{
        .{
            .idx = 0,
            .params = &[_]u8{@intFromEnum(MessageMagic.type_varchar)},
            .since = 0,
        },
        .{
            .idx = 1,
            .params = &[_]u8{@intFromEnum(MessageMagic.type_array)},
            .since = 0,
        },
    },

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn objectName(self: *Self) []const u8 {
        _ = self;
        return "my_manager_v1";
    }

    pub fn c2s(self: *const Self) []const Method {
        return self.c2s_methods;
    }

    pub fn s2c(self: *const Self) []const Method {
        return self.s2c_methods;
    }
};

pub const MyObjectV1Spec = struct {
    c2s_methods: []const Method = &.{
        .{
            .idx = 0,
            .params = &[_]u8{@intFromEnum(MessageMagic.type_varchar)},
            .returns_type = "",
            .since = 0,
        },
        .{
            .idx = 1,
            .params = &[_]u8{@intFromEnum(MessageMagic.type_uint)},
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

    s2c_methods: []const Method = &.{
        .{
            .idx = 0,
            .params = &[_]u8{@intFromEnum(MessageMagic.type_varchar)},
            .since = 0,
        },
    },

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn objectName(self: *Self) []const u8 {
        _ = self;
        return "my_object_v1";
    }

    pub fn c2s(self: *const Self) []const Method {
        return self.c2s_methods;
    }

    pub fn s2c(self: *const Self) []const Method {
        return self.s2c_methods;
    }
};

pub const MyManagerV1 = struct {
    pub const interface = ProtocolObjectSpec.from(&MyManagerV1Spec.init());
};

pub const MyObjectV1 = struct {
    pub const interface = ProtocolObjectSpec.from(&MyObjectV1Spec.init());
};

pub const TestProtocolV1ProtocolSpec = struct {
    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn specName(self: *Self) []const u8 {
        _ = self;
        return "test_protocol_v1";
    }

    pub fn specVer(self: *Self) u32 {
        _ = self;
        return 1;
    }

    pub fn objects(self: *Self) []const ProtocolObjectSpec {
        _ = self;
        return &.{
            MyManagerV1.interface,
            MyObjectV1.interface,
        };
    }
};

pub const protocol = TestProtocolV1ProtocolSpec{};
