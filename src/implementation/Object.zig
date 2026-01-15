const std = @import("std");

const mem = std.mem;

const ClientSocket = @import("../client/ClientSocket.zig");
const ServerSocket = @import("../server/ServerSocket.zig");

const Defaults = struct {
    fn getClientSock(ptr: *anyopaque) ?*ClientSocket {
        _ = ptr;
        return null;
    }

    fn getServerSock(ptr: *anyopaque) ?*ServerSocket {
        _ = ptr;
        return null;
    }

    pub fn err(ptr: *anyopaque, alloc: mem.Allocator, id: u32, message: [:0]const u8) !void {
        _ = alloc;
        _ = ptr;
        _ = id;
        _ = message;
    }
};

pub const VTable = struct {
    getClientSock: *const fn (*anyopaque) ?*ClientSocket = Defaults.getClientSock,
    getServerSock: *const fn (*anyopaque) ?*ServerSocket = Defaults.getServerSock,
    setData: *const fn (*anyopaque, ?*anyopaque) void,
    getData: *const fn (*anyopaque) ?*anyopaque,
    err: *const fn (*anyopaque, mem.Allocator, u32, [:0]const u8) anyerror!void = Defaults.err,
    deinit: *const fn (*anyopaque) void,
    setOnDeinit: *const fn (*anyopaque, *const fn () void) void,
    getOnDeinit: *const fn (*anyopaque) ?*const fn () void,
};

ptr: *anyopaque,
vtable: *const VTable,

const Self = @This();

pub fn getClientSock(self: *Self) ?*ClientSocket {
    return self.vtable.getClientSock(self.ptr);
}

pub fn getServerSock(self: *Self) ?*ServerSocket {
    return self.vtable.getServerSock(self.ptr);
}

pub fn setData(self: *Self, data: *anyopaque) void {
    self.vtable.setData(self.ptr, data);
}

pub fn getData(self: *Self) *anyopaque {
    return self.vtable.getData(self.ptr);
}

pub fn err(self: *const Self, alloc: mem.Allocator, id: u32, message: [:0]const u8) !void {
    try self.vtable.err(self.ptr, alloc, id, message);
}

pub fn deinit(self: *Self, id: u32, message: [:0]const u8) void {
    self.vtable.deinit(self.ptr, id, message);
}

pub fn setOnDeinit(self: *Self, cb: *const fn () void) void {
    self.vtable.setOnDeinit(self.ptr, cb);
}

pub fn getOnDeinit(self: *const Self) ?*const fn () void {
    return self.vtable.getOnDeinit(self.ptr);
}
