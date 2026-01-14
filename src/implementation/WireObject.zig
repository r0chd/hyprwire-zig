const std = @import("std");
const types = @import("types.zig");

const ServerSocket = @import("../server/ServerSocket.zig");
const ClientSocket = @import("../server/ServerClient.zig");
const Object = @import("Object.zig");
const Method = types.Method;

methodsOutFn: *const fn () []Method,
methodsInFn: *const fn () []Method,

data: ?*anyopaque = null,
listeners: []*anyopaque = &.{},
on_deinit: ?*const fn () void = null,
id: u32 = 0,
version: u32 = 0,
seq: u32 = 1,
protocol_name: []const u8 = "",

pub fn object(self: *Self) Object {
    return .{
        .ptr = self,
        .vtable = &.{
            .getClientSock = Self.getClientSock,
            .getServerSock = Self.getServerSock,
            .getData = Self.getData,
            .setData = Self.setData,
            .err = Self.err,
            .deinit = Self.deinit,
            .setOnDeinit = Self.setOnDeinit,
            .getOnDeinit = Self.getOnDeinit,
        },
    };
}

const Self = @This();

pub fn methodsOut(self: *Self) []Method {
    return self.methodsOut();
}

pub fn methodsIn(self: *Self) []Method {
    return self.methodsIn();
}

pub fn getData(ptr: *anyopaque) ?*anyopaque {
    const self: *const Self = @ptrCast(@alignCast(ptr));

    return self.data;
}

pub fn setData(ptr: *anyopaque, data: ?*anyopaque) void {
    const self: *const Self = @ptrCast(@alignCast(ptr));

    self.data = data;
}

pub fn getClientSock(ptr: *anyopaque) ?*ClientSocket {
    _ = ptr;
    return null;
}

pub fn getServerSock(ptr: *anyopaque) ?*ServerSocket {
    _ = ptr;
    return null;
}

pub fn err(ptr: *anyopaque, id: u32, message: [:0]const u8) void {
    _ = ptr;
    _ = id;
    _ = message;
}

pub fn deinit(ptr: *anyopaque, id: u32, message: [:0]const u8) void {
    _ = id;
    _ = message;
    const self: *const Self = @ptrCast(@alignCast(ptr));
    if (self.on_deinit) |onDeinit| {
        onDeinit();
    }
}

pub fn setOnDeinit(ptr: *anyopaque, cb: *const fn () void) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.on_deinit = cb;
}

pub fn getOnDeinit(ptr: *anyopaque) ?*const fn () void {
    const self: *const Self = @ptrCast(@alignCast(ptr));
    return self.on_deinit;
}

pub fn call(id: u32, args: anytype) void {
    _ = id;
    const ArgsType = @TypeOf(args);
    const args_type_info = @typeInfo(ArgsType);
    if (args_type_info != .@"struct") {
        @compileError("expected tuple or struct argument, found " ++ @typeName(ArgsType));
    }

    const fields_info = args_type_info.@"struct".fields;
    const max_format_args = @typeInfo(std.fmt.ArgSetType).int.bits;
    if (fields_info.len > max_format_args) {
        @compileError("32 arguments max are supported per call");
    }

    inline for (fields_info) |field_info| {
        const arg = @field(args, field_info.name);
        _ = arg;
    }
}
