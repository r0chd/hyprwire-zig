const std = @import("std");

const time = std.time;

pub const version = @import("build_options").version;
pub const types = @import("implementation/types.zig");
pub const messages = @import("message/messages/root.zig");

pub const ServerSocket = @import("server/ServerSocket.zig");
pub const ClientSocket = @import("client/ClientSocket.zig");

pub const MessageMagic = @import("types/MessageMagic.zig").MessageMagic;

// Reexports for codegen
pub const Trait = @import("trait").Trait;
pub const FallbackAllocator = @import("helpers").FallbackAllocator;

const ServerObject = @import("server/ServerObject.zig");
const ClientObject = @import("client/ClientObject.zig");

var start: ?time.Instant = null;

pub fn steadyMillis() u64 {
    const now = time.Instant.now() catch return 0;
    if (start) |s| {
        return now.since(s);
    } else {
        start = now;
        return 0;
    }
}

test {
    std.testing.refAllDecls(@This());
}
