const types = @import("hyprwire").types;
const MessageMagic = @import("hyprwire").MessageMagic;

const Method = types.Method;
const ProtocolSpec = types.ProtocolSpec;
const ProtocolObjectSpec = types.ProtocolObjectSpec;

pub const spec = ProtocolSpec{
    .spec_name = "test_protocol_v1",
    .spec_ver = 1,
    .objects = &.{
        ProtocolObjectSpec{
            .object_name = "my_manager_v1",
            .c2s_methods = &.{
                Method{ .idx = 0, .params = &[_]u8{}, .returns_type = @intFromEnum(MessageMagic.type_seq), .since = 1 },
                Method{ .idx = 1, .params = &[_]u8{}, .returns_type = @intFromEnum(MessageMagic.type_seq), .since = 1 },
                Method{ .idx = 2, .params = &[_]u8{}, .returns_type = @intFromEnum(MessageMagic.type_seq), .since = 1 },
                Method{ .idx = 3, .params = &[_]u8{}, .returns_type = @intFromEnum(MessageMagic.type_seq), .since = 1 },
                Method{ .idx = 4, .params = &[_]u8{}, .returns_type = @intFromEnum(MessageMagic.type_seq), .since = 1 },
            },
            .s2c_methods = &.{
                Method{ .idx = 0, .params = &[_]u8{}, .returns_type = @intFromEnum(MessageMagic.type_seq), .since = 1 },
                Method{ .idx = 1, .params = &[_]u8{}, .returns_type = @intFromEnum(MessageMagic.type_seq), .since = 1 },
            },
        },
        ProtocolObjectSpec{
            .object_name = "my_object_v1",
            .c2s_methods = &.{
                Method{ .idx = 0, .params = &[_]u8{}, .returns_type = "", .since = 1 },
                Method{ .idx = 1, .params = &[_]u8{}, .returns_type = "", .since = 1 },
                Method{ .idx = 2, .params = &[_]u8{}, .returns_type = "", .since = 1 },
            },
            .s2c_methods = &.{
                Method{ .idx = 0, .params = &[_]u8{}, .returns_type = "", .since = 1 },
            },
        },
    },
};
