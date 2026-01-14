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

    fn deinit(ptr: *anyopaque) void {
        const self: *const Self = @ptrCast(@alignCast(ptr));
        if (self.getOnDeinit()) |onDeinit| {
            onDeinit();
        }
    }

    pub fn err(self: *Self, id: u32, message: [:0]const u8) void {
        _ = self;
        _ = id;
        _ = message;
    }
};

pub const VTable = struct {
    getClientSock: *const fn (*anyopaque) ?*ClientSocket = Defaults.getClientSock,
    getServerSock: *const fn (*anyopaque) ?*ServerSocket = Defaults.getServerSock,
    setData: *const fn (*anyopaque, ?*anyopaque) void,
    getData: *const fn (*anyopaque) ?*anyopaque,
    err: *const fn (*anyopaque, u32, [:0]const u8) Defaults.err,
    deinit: *const fn (*anyopaque, u32, [:0]const u8) void = Defaults.deinit,
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

pub fn err(self: *Self, id: u32, message: [:0]const u8) void {
    self.vtable.err(self.ptr, id, message);
}

pub fn deinit(self: *Self, id: u32, message: [:0]const u8) void {
    self.vtable.deinit(self.ptr, id, message);
}

pub fn setOnDeinit(self: *Self, cb: *const fn () void) void {
    self.vtable.setOnDeinit(self.ptr, cb);
}

pub fn getOnDeinit(self: *Self) ?*const fn () void {
    return self.vtable.getOnDeinit(self.ptr);
}
