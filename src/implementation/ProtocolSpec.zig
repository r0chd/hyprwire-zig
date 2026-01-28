const Method = @import("types.zig").Method;

object_name: []const u8,
c2s_methods: []const Method,
s2c_methods: []const Method,

const Self = @This();

pub fn objectName(self: *const Self) []const u8 {
    return self.object_name;
}

pub fn c2s(self: *const Self) []const Method {
    return self.c2s_methods;
}

pub fn s2c(self: *const Self) []const Method {
    return self.s2c_methods;
}

test {
    std.testing.refAllDecls(@This());
}
