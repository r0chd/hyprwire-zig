const std = @import("std");
const types = @import("types.zig");
const c = @cImport(@cInclude("sys/socket.h"));

const mem = std.mem;

const Message = @import("../message/messages/root.zig").Message;
const ServerSocket = @import("../server/ServerSocket.zig");
const ClientSocket = @import("../server/ServerClient.zig");
const Object = @import("Object.zig");
const Method = types.Method;
const MessageMagic = @import("../types/MessageMagic.zig").MessageMagic;

pub const VTable = struct {
    getListeners: *const fn (*anyopaque) std.ArrayList(*const fn (*anyopaque) void),
    methodsOut: *const fn (*anyopaque) []const Method,
    methodsIn: *const fn (*anyopaque) []const Method,
    errd: *const fn (*anyopaque) void,
    sendMessage: *const fn (*anyopaque, mem.Allocator, Message) anyerror!void,
    server: *const fn (*anyopaque) bool,
};

ptr: *anyopaque,
vtable: *const VTable,

pub fn object(self: *Self) Object {
    return .{
        .ptr = self,
        .vtable = &.{
            .getData = Self.getData,
            .setData = Self.setData,
            .setOnDeinit = Self.setOnDeinit,
            .getOnDeinit = Self.getOnDeinit,
        },
    };
}

const Self = @This();

pub fn call(ptr: *anyopaque, id: u32, args: anytype) !u32 {
    const self: *const Self = @ptrCast(@alignCast(ptr));
    _ = self;
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

    return 0;
}

pub fn listen(ptr: *anyopaque, gpa: mem.Allocator, id: u32, callback: *const fn (*anyopaque) void) !void {
    const self: *const Self = @ptrCast(@alignCast(ptr));
    var listeners = self.vtable.getListeners(self.ptr);

    if (listeners.items.len <= id) {
        try listeners.resize(gpa, id + 1);
    }
    listeners.appendAssumeCapacity(callback);
}

pub fn called(ptr: *anyopaque, gpa: mem.Allocator, id: u32, data: []const u8, fds: std.ArrayList(i32)) !void {
    const self: *const Self = @ptrCast(@alignCast(ptr));
    const obj: Object = self.object();

    const methods = self.vtable.methodsIn(self.ptr);

    if (id >= methods.len) {
        const msg = try std.fmt.allocPrintZ(gpa, "invalid method {} for object {}", .{ id, self.id });
        defer gpa.free(msg);
        try obj.err(gpa, self.id, msg);
        return;
    }

    if (id >= self.vtable.getListeners(self.ptr) or self.vtable.getListeners(self.ptr)[id] == null) {
        return;
    }

    const method = methods[id];

    if (method.since > self.version) {
        const msg = try std.fmt.allocPrintZ(gpa, "method {} since {} but has {}", .{ id, method.since, self.version });
        defer gpa.free(msg);
        try obj.err(gpa, self.id, msg);
        return;
    }

    var params = std.ArrayList(u8).init(gpa);
    defer params.deinit();

    if (method.returns_type.len > 0) {
        try params.append(@intFromEnum(MessageMagic.type_seq));
    }
    try params.appendSlice(method.params);

    var data_idx: usize = 0;
    var param_idx: usize = 0;

    while (param_idx < params.items.len) : (param_idx += 1) {
        if (data_idx >= data.len) {
            const msg = try std.fmt.allocPrintZ(gpa, "method {} param idx {}: unexpected end of data", .{ id, param_idx });
            defer gpa.free(msg);
            try self.err(gpa, self.id, msg);
            return;
        }

        const param_type = params.items[param_idx];
        const wire_type = data[data_idx];

        if (param_type != wire_type) {
            const msg = try std.fmt.allocPrintZ(gpa, "method {} param idx {} should be {} but was {}", .{ id, param_idx, param_type, wire_type });
            defer gpa.free(msg);
            try self.err(gpa, self.id, msg);
            return;
        }

        data_idx += 1;

        switch (@as(MessageMagic, @enumFromInt(wire_type))) {
            .end => {
                param_idx += 1;
                break;
            },
            .type_fd => {
                if (fds.len == 0) {
                    const msg = try std.fmt.allocPrintZ(gpa, "method {} param idx {}: expected FD but none provided", .{ id, param_idx });
                    defer gpa.free(msg);
                    try self.err(gpa, self.id, msg);
                    return;
                }
            },
            .type_uint, .type_int, .type_f32, .type_seq, .type_object_id => {
                if (data_idx + 4 > data.len) {
                    const msg = try std.fmt.allocPrintZ(gpa, "method {} param idx {}: incomplete data", .{ id, param_idx });
                    defer gpa.free(msg);
                    try self.err(gpa, self.id, msg);
                    return;
                }
                data_idx += 4;
            },
            .type_varchar => {
                if (data_idx >= data.len) {
                    const msg = try std.fmt.allocPrintZ(gpa, "method {} param idx {}: incomplete varchar length", .{ id, param_idx });
                    defer gpa.free(msg);
                    try self.err(gpa, self.id, msg);
                    return;
                }
                var str_len: usize = 0;
                var shift: u6 = 0;
                var len_idx = data_idx;
                while (len_idx < data.len) {
                    const byte = data[len_idx];
                    str_len |= @as(usize, byte & 0x7F) << shift;
                    len_idx += 1;
                    if ((byte & 0x80) == 0) break;
                    shift += 7;
                    if (shift >= 64) {
                        const msg = try std.fmt.allocPrintZ(gpa, "method {} param idx {}: invalid varchar length", .{ id, param_idx });
                        defer gpa.free(msg);
                        try self.err(gpa, self.id, msg);
                        return;
                    }
                }
                if (len_idx + str_len > data.len) {
                    const msg = try std.fmt.allocPrintZ(gpa, "method {} param idx {}: incomplete varchar data", .{ id, param_idx });
                    defer gpa.free(msg);
                    try self.err(gpa, self.id, msg);
                    return;
                }
                data_idx = len_idx + str_len;
            },
            .type_array => {
                param_idx += 1;
                if (param_idx >= params.items.len or data_idx >= data.len) {
                    const msg = try std.fmt.allocPrintZ(gpa, "method {} param idx {}: incomplete array type", .{ id, param_idx });
                    defer gpa.free(msg);
                    try self.err(gpa, self.id, msg);
                    return;
                }
                const arr_type = params.items[param_idx];
                const wire_arr_type = data[data_idx];
                if (arr_type != wire_arr_type) {
                    const msg = try std.fmt.allocPrintZ(gpa, "method {} param idx {}: array type mismatch", .{ id, param_idx });
                    defer gpa.free(msg);
                    try self.err(gpa, self.id, msg);
                    return;
                }
                data_idx += 1;
                var arr_len: usize = 0;
                var shift: u6 = 0;
                var len_idx = data_idx;
                while (len_idx < data.len) {
                    const byte = data[len_idx];
                    arr_len |= @as(usize, byte & 0x7F) << shift;
                    len_idx += 1;
                    if ((byte & 0x80) == 0) break;
                    shift += 7;
                    if (shift >= 64) {
                        const msg = try std.fmt.allocPrintZ(gpa, "method {} param idx {}: invalid array length", .{ id, param_idx });
                        defer gpa.free(msg);
                        try self.err(gpa, self.id, msg);
                        return;
                    }
                }
                data_idx = len_idx;
                switch (@as(MessageMagic, @enumFromInt(arr_type))) {
                    .type_uint, .type_int, .type_f32, .type_object_id => {
                        if (data_idx + arr_len * 4 > data.len) {
                            const msg = try std.fmt.allocPrintZ(gpa, "method {} param idx {}: incomplete array data", .{ id, param_idx });
                            defer gpa.free(msg);
                            try self.err(gpa, self.id, msg);
                            return;
                        }
                        data_idx += arr_len * 4;
                    },
                    .type_varchar => {
                        var i: usize = 0;
                        while (i < arr_len) : (i += 1) {
                            if (data_idx >= data.len) {
                                const msg = try std.fmt.allocPrintZ(gpa, "method {} param idx {}: incomplete array element {}", .{ id, param_idx, i });
                                defer gpa.free(msg);
                                try self.err(gpa, self.id, msg);
                                return;
                            }
                            var elem_len: usize = 0;
                            var elem_shift: u6 = 0;
                            var elem_len_idx = data_idx;
                            while (elem_len_idx < data.len) {
                                const byte = data[elem_len_idx];
                                elem_len |= @as(usize, byte & 0x7F) << elem_shift;
                                elem_len_idx += 1;
                                if ((byte & 0x80) == 0) break;
                                elem_shift += 7;
                                if (elem_shift >= 64) {
                                    const msg = try std.fmt.allocPrintZ(gpa, "method {} param idx {}: invalid array element length", .{ id, param_idx });
                                    defer gpa.free(msg);
                                    try self.err(gpa, self.id, msg);
                                    return;
                                }
                            }
                            if (elem_len_idx + elem_len > data.len) {
                                const msg = try std.fmt.allocPrintZ(gpa, "method {} param idx {}: incomplete array element data", .{ id, param_idx });
                                defer gpa.free(msg);
                                try self.err(gpa, self.id, msg);
                                return;
                            }
                            data_idx = elem_len_idx + elem_len;
                        }
                    },
                    else => {},
                }
            },
            .type_object => {
                if (data_idx + 4 > data.len) {
                    const msg = try std.fmt.allocPrintZ(gpa, "method {} param idx {}: incomplete object ID", .{ id, param_idx });
                    defer gpa.free(msg);
                    try self.err(gpa, self.id, msg);
                    return;
                }
                data_idx += 4;
                var name_len: usize = 0;
                var shift: u6 = 0;
                var len_idx = data_idx;
                while (len_idx < data.len) {
                    const byte = data[len_idx];
                    name_len |= @as(usize, byte & 0x7F) << shift;
                    len_idx += 1;
                    if ((byte & 0x80) == 0) break;
                    shift += 7;
                    if (shift >= 64) {
                        const msg = try std.fmt.allocPrintZ(gpa, "method {} param idx {}: invalid object name length", .{ id, param_idx });
                        defer gpa.free(msg);
                        try self.err(gpa, self.id, msg);
                        return;
                    }
                }
                if (len_idx + name_len > data.len) {
                    const msg = try std.fmt.allocPrintZ(gpa, "method {} param idx {}: incomplete object name", .{ id, param_idx });
                    defer gpa.free(msg);
                    try self.err(gpa, self.id, msg);
                    return;
                }
                data_idx = len_idx + name_len;
            },
        }
    }

    const callback = self.listeners[id];
    var ffi_types = std.ArrayList(*c.ffi_type).init(gpa);
    defer ffi_types.deinit();

    try ffi_types.append(&c.ffi_type_pointer);

    for (params.items) |param_type| {
        const ffi_type = switch (@as(MessageMagic, @enumFromInt(param_type))) {
            .type_uint => &c.ffi_type_uint32,
            .type_int => &c.ffi_type_sint32,
            .type_f32 => &c.ffi_type_float,
            .type_seq => &c.ffi_type_uint32,
            .type_object_id => &c.ffi_type_uint32,
            .type_varchar => &c.ffi_type_pointer,
            .type_fd => &c.ffi_type_sint32,
            else => &c.ffi_type_pointer,
        };
        try ffi_types.append(ffi_type);
    }

    var cif: c.ffi_cif = undefined;
    if (c.ffi_prep_cif(&cif, c.FFI_DEFAULT_ABI, @intCast(ffi_types.items.len), &c.ffi_type_void, ffi_types.items.ptr) != c.FFI_OK) {
        return error.FfiFailed;
    }

    var arg_values = std.ArrayList(*anyopaque).init(gpa);
    defer arg_values.deinit();

    try arg_values.append(@ptrCast(self));

    data_idx = 0;
    var fd_idx: usize = 0;

    for (params.items) |param_type| {
        const value = switch (@as(MessageMagic, @enumFromInt(param_type))) {
            .type_uint => blk: {
                const val = std.mem.bytesToValue(u32, data[data_idx..][0..4]);
                data_idx += 4;
                const buf = try gpa.create(u32);
                buf.* = val;
                break :blk buf;
            },
            .type_int => blk: {
                const val = std.mem.bytesToValue(i32, data[data_idx..][0..4]);
                data_idx += 4;
                const buf = try gpa.create(i32);
                buf.* = val;
                break :blk buf;
            },
            .type_f32 => blk: {
                const val = std.mem.bytesToValue(f32, data[data_idx..][0..4]);
                data_idx += 4;
                const buf = try gpa.create(f32);
                buf.* = val;
                break :blk buf;
            },
            .type_fd => blk: {
                const val = fds[fd_idx];
                fd_idx += 1;
                const buf = try gpa.create(i32);
                buf.* = val;
                break :blk buf;
            },
            .type_varchar => blk: {
                var str_len: usize = 0;
                var shift: u6 = 0;
                var len_idx = data_idx;
                while (len_idx < data.len) : (len_idx += 1) {
                    const byte = data[len_idx];
                    str_len |= @as(usize, byte & 0x7F) << shift;
                    if ((byte & 0x80) == 0) break;
                    shift += 7;
                }
                len_idx += 1;

                const str = data[len_idx..][0..str_len];
                data_idx = len_idx + str_len;

                const buf = try gpa.allocSentinel(u8, str_len, 0);
                @memcpy(buf, str);
                break :blk buf.ptr;
            },
            else => null,
        };

        if (value) |v| {
            try arg_values.append(v);
        }
    }

    c.ffi_call(&cif, @ptrCast(callback), null, arg_values.items.ptr);

    for (arg_values.items[1..]) |arg| {
        gpa.destroy(arg);
    }
}

pub fn getData(ptr: *anyopaque) ?*anyopaque {
    const self: *const Self = @ptrCast(@alignCast(ptr));
    return self.data;
}

pub fn setData(ptr: *anyopaque, data: ?*anyopaque) void {
    const self: *const Self = @ptrCast(@alignCast(ptr));
    self.data = data;
}

pub fn setOnDeinit(ptr: *anyopaque, cb: *const fn () void) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.on_deinit = cb;
}

pub fn getOnDeinit(ptr: *anyopaque) ?*const fn () void {
    const self: *const Self = @ptrCast(@alignCast(ptr));
    return self.on_deinit;
}
