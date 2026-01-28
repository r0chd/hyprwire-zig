pub const MessageMagic = enum(u8) {
    /// Signifies an end of a message
    end = 0x0,

    /// Primitive type identifiers
    type_uint = 0x10,
    type_int = 0x11,
    type_f32 = 0x12,
    type_seq = 0x13,
    type_object_id = 0x14,

    /// Variable length types
    /// [magic : 1B][len : VLQ][data : len B]
    type_varchar = 0x20,

    /// [magic : 1B][type : 1B][n_els : VLQ]{ [data...] }
    type_array = 0x21,

    /// [magic : 1B][id : UINT][name_len : VLQ][object name ...]
    type_object = 0x22,

    /// Special types
    /// FD has size 0. It's passed via control.
    type_fd = 0x40,
};

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
