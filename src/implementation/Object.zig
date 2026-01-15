const std = @import("std");
const helpers = @import("helpers");

const mem = std.mem;

const ClientSocket = @import("../client/ClientSocket.zig");
const ServerSocket = @import("../server/ServerSocket.zig");

pub const Object = helpers.trait.Trait(.{
    .clientSock = fn () ?*ClientSocket,
    .serverSock = fn () ?*ServerSocket,
    .setData = fn (?*anyopaque) void,
    .getData = fn () ?*anyopaque,
    .err = fn (mem.Allocator, u32, [:0]const u8) anyerror!void,
    .deinit = fn () void,
    .setOnDeinit = fn (*const fn () void) void,
}, null);
