const std = @import("std");
const types = @import("types.zig");

const mem = std.mem;

const ServerClient = @import("../server/ServerClient.zig");
const ClientSocket = @import("../client/ClientSocket.zig");
const ServerSocket = @import("../server/ServerSocket.zig");
const Trait = @import("trait").Trait;

pub const Object = Trait(.{
    .call = fn (std.Io, mem.Allocator, u32, *types.Args) anyerror!u32,
    .listen = fn (mem.Allocator, u32, *const fn (*anyopaque) void) anyerror!void,
    .clientSock = fn () ?*ClientSocket,
    .serverSock = fn () ?*ServerSocket,
    .setData = fn (*anyopaque) void,
    .getData = fn () ?*anyopaque,
    .@"error" = fn (std.Io, mem.Allocator, u32, [:0]const u8) void,
    .deinit = fn (mem.Allocator) void,
    .setOnDeinit = fn (*const fn () void) void,
    .getClient = fn () ?*ServerClient,
}, null);

test {
    std.testing.refAllDecls(@This());
}
