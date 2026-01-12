const std = @import("std");
const types = @import("../implementation/types.zig");

const posix = std.posix;

const ProtocolClientImplementation = types.ProtocolClientImplementation;
const ProtocolSpec = types.ProtocolSpec;

fd: i32,
impls: std.ArrayList(*const ProtocolClientImplementation) = .empty,
server_specs: std.ArrayList(*const ProtocolSpec) = .empty,
pollfds: std.ArrayList(posix.pollfd) = .empty,

const Self = @This();
