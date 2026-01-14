const ClientSocket = @import("../client/ClientSocket.zig");
const ServerSocket = @import("../server/ServerSocket.zig");

const Self = @This();

clientSockFn: *const fn () ?*ClientSocket,
serverSockFn: *const fn () ?*ServerSocket,
setDataFn: *const fn (data: *anyopaque) void,
getDataFn: *const fn () *anyopaque,
errorFn: *const fn (id: u32, message: [:0]const u8) void,
