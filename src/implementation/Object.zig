const std = @import("std");
const types = @import("types.zig");

const mem = std.mem;

const ServerClient = @import("../server/ServerClient.zig");
const ClientSocket = @import("../client/ClientSocket.zig");
const ServerSocket = @import("../server/ServerSocket.zig");

pub const VTable = struct {
    call: *const fn (*anyopaque, std.Io, mem.Allocator, u32, *types.Args) anyerror!u32,
    listen: *const fn (*anyopaque, mem.Allocator, u32, *const fn (*anyopaque) void) anyerror!void,
    clientSock: *const fn (*anyopaque) ?*ClientSocket,
    serverSock: *const fn (*anyopaque) ?*ServerSocket,
    setData: *const fn (*anyopaque, *anyopaque) void,
    getData: *const fn (*anyopaque) ?*anyopaque,
    @"error": *const fn (*anyopaque, std.Io, mem.Allocator, u32, [:0]const u8) void,
    deinit: *const fn (*anyopaque, mem.Allocator) void,
    setOnDeinit: *const fn (*anyopaque, *const fn () void) void,
    getClient: *const fn (*anyopaque) ?*ServerClient,
};

ptr: *anyopaque,
vtable: *const VTable,

const Self = @This();

pub fn from(impl: anytype) Self {
    const ImplPtr = @TypeOf(impl);
    const impl_info = @typeInfo(ImplPtr);

    if (impl_info != .pointer) {
        @compileError("from() requires a pointer to an implementation type");
    }

    const Impl = impl_info.pointer.child;

    if (@hasDecl(Impl, "vtable")) {
        const vtable_type = @TypeOf(Impl.vtable);
        if (@hasField(vtable_type, "object")) {
            return .{
                .ptr = impl,
                .vtable = &Impl.vtable.object,
            };
        }
    }

    @compileError("Implementation type must have a 'vtable' declaration with an 'object' field of type VTable");
}

pub fn call(self: Self, io: std.Io, gpa: mem.Allocator, id: u32, args: *types.Args) anyerror!u32 {
    return self.vtable.call(self.ptr, io, gpa, id, args);
}

pub fn listen(self: Self, gpa: mem.Allocator, id: u32, callback: *const fn (*anyopaque) void) anyerror!void {
    return self.vtable.listen(self.ptr, gpa, id, callback);
}

pub fn clientSock(self: Self) ?*ClientSocket {
    return self.vtable.clientSock(self.ptr);
}

pub fn serverSock(self: Self) ?*ServerSocket {
    return self.vtable.serverSock(self.ptr);
}

pub fn setData(self: Self, data: *anyopaque) void {
    self.vtable.setData(self.ptr, data);
}

pub fn getData(self: Self) ?*anyopaque {
    return self.vtable.getData(self.ptr);
}

pub fn @"error"(self: Self, io: std.Io, gpa: mem.Allocator, id: u32, message: [:0]const u8) void {
    self.vtable.@"error"(self.ptr, io, gpa, id, message);
}

pub fn deinit(self: Self, gpa: mem.Allocator) void {
    self.vtable.deinit(self.ptr, gpa);
}

pub fn setOnDeinit(self: Self, cb: *const fn () void) void {
    self.vtable.setOnDeinit(self.ptr, cb);
}

pub fn getClient(self: Self) ?*ServerClient {
    return self.vtable.getClient(self.ptr);
}

test {
    std.testing.refAllDecls(@This());
}
