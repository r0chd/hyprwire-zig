pub const Method = struct {
    idx: u32 = 0,
    params: []const u8,
    returns_type: []const u8 = "",
    since: u32 = 0,
};

pub const ProtocolObjectSpec = struct {
    object_name: []const u8,
    c2s_methods: []const Method,
    s2c_methods: []const Method,

    const Self = @This();

    pub fn objectName(self: Self) []const u8 {
        return self.object_name;
    }

    pub fn c2s(self: Self) []const Method {
        return self.c2s_methods;
    }

    pub fn s2c(self: Self) []const Method {
        return self.s2c_methods;
    }
};

pub const ProtocolSpec = struct {
    spec_name: []const u8,
    spec_ver: u32,
    objects: []const ProtocolObjectSpec,

    const Self = @This();

    pub fn specName(self: Self) []const u8 {
        return self.spec_name;
    }

    pub fn specVer(self: Self) u32 {
        return self.spec_ver;
    }

    pub fn getObjects(self: Self) []const ProtocolObjectSpec {
        return self.objects;
    }
};

pub const ServerObjectImplementation = struct {
    object_name: []const u8 = "",
    version: u32 = 0,
    on_bind: ?*const fn (*anyopaque) void = null,
};

pub const ProtocolServerImplementation = struct {
    protocol_spec: *const ProtocolSpec,
    implementations: []const ServerObjectImplementation,

    const Self = @This();

    pub fn protocol(self: Self) *const ProtocolSpec {
        return self.protocol_spec;
    }

    pub fn getImplementations(self: Self) []const ServerObjectImplementation {
        return self.implementations;
    }
};
