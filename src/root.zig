const std = @import("std");
const time = std.time;
pub const version = @import("build_options").version;

pub const proto = @import("protocols");

// Reexports for codegen
pub const FallbackAllocator = @import("helpers").FallbackAllocator;
pub const Trait = @import("trait").Trait;

pub const ClientSocket = @import("client/ClientSocket.zig");
pub const types = @import("implementation/types.zig");
pub const messages = @import("message/messages/root.zig");
pub const ServerSocket = @import("server/ServerSocket.zig");
pub const MessageMagic = @import("types/MessageMagic.zig").MessageMagic;

var start: ?time.Instant = null;

pub fn steadyMillis() f32 {
    const now = time.Instant.now() catch return 0;
    if (start) |s| {
        return @as(f32, @floatFromInt(now.since(s))) / 1_000_000.0;
    } else {
        start = now;
        return 0;
    }
}

test {
    std.testing.refAllDecls(@This());
}
