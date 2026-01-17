const std = @import("std");
const types = @import("types.zig");
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("ffi.h");
});
const helpers = @import("helpers");

const mem = std.mem;

const Message = @import("../message/messages/root.zig").Message;
const ServerSocket = @import("../server/ServerSocket.zig");
const ClientSocket = @import("../server/ServerClient.zig");
const Object = @import("Object.zig").Object;
const Method = types.Method;
const MessageMagic = @import("../types/MessageMagic.zig").MessageMagic;

pub const WireObject = helpers.trait.Trait(.{
    .getVersion = fn () u32,
    .getListeners = fn () []?*anyopaque,
    .methodsOut = fn () []const Method,
    .methodsIn = fn () []const Method,
    .errd = fn () void,
    .sendMessage = fn (mem.Allocator, Message) anyerror!void,
    .server = fn () bool,
    .getId = fn () u32,
}, .{Object});

pub fn called(self: WireObject, gpa: mem.Allocator, id: u32, data: []const u8, fds: []const i32) !void {
    const methods = self.vtable.methodsIn(self.ptr);

    if (id >= methods.len) {
        const msg = try std.fmt.allocPrintSentinel(gpa, "invalid method {} for object {}", .{ id, self.vtable.getId(self.ptr) }, 0);
        defer gpa.free(msg);
        try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
        return;
    }

    if (self.vtable.getListeners(self.ptr).len <= id or self.vtable.getListeners(self.ptr)[id] == null) {
        return;
    }

    const method = methods[id];

    if (method.since > self.vtable.getVersion(self.ptr)) {
        const msg = try std.fmt.allocPrintSentinel(gpa, "method {} since {} but has {}", .{ id, method.since, self.vtable.getVersion(self.ptr) }, 0);
        defer gpa.free(msg);
        try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
        return;
    }

    var params: std.ArrayList(u8) = .empty;
    defer params.deinit(gpa);

    if (method.returns_type.len > 0) {
        try params.append(gpa, @intFromEnum(MessageMagic.type_seq));
    }
    try params.appendSlice(gpa, method.params);

    var data_idx: usize = 0;
    var param_idx: usize = 0;

    while (param_idx < params.items.len) : (param_idx += 1) {
        if (data_idx >= data.len) {
            const msg = try std.fmt.allocPrintSentinel(gpa, "method {} param idx {}: unexpected end of data", .{ id, param_idx }, 0);
            defer gpa.free(msg);
            try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
            return;
        }

        const param_type = params.items[param_idx];
        const wire_type = data[data_idx];

        if (param_type != wire_type) {
            const msg = try std.fmt.allocPrintSentinel(gpa, "method {} param idx {} should be {} but was {}", .{ id, param_idx, param_type, wire_type }, 0);
            defer gpa.free(msg);
            try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
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
                    const msg = try std.fmt.allocPrintSentinel(gpa, "method {} param idx {}: expected FD but none provided", .{ id, param_idx }, 0);
                    defer gpa.free(msg);
                    try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
                    return;
                }
            },
            .type_uint, .type_int, .type_f32, .type_seq, .type_object_id => {
                if (data_idx + 4 > data.len) {
                    const msg = try std.fmt.allocPrintSentinel(gpa, "method {} param idx {}: incomplete data", .{ id, param_idx }, 0);
                    defer gpa.free(msg);
                    try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
                    return;
                }
                data_idx += 4;
            },
            .type_varchar => {
                if (data_idx >= data.len) {
                    const msg = try std.fmt.allocPrintSentinel(gpa, "method {} param idx {}: incomplete varchar length", .{ id, param_idx }, 0);
                    defer gpa.free(msg);
                    try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
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
                        const msg = try std.fmt.allocPrintSentinel(gpa, "method {} param idx {}: invalid varchar length", .{ id, param_idx }, 0);
                        defer gpa.free(msg);
                        try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
                        return;
                    }
                }
                if (len_idx + str_len > data.len) {
                    const msg = try std.fmt.allocPrintSentinel(gpa, "method {} param idx {}: incomplete varchar data", .{ id, param_idx }, 0);
                    defer gpa.free(msg);
                    try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
                    return;
                }
                data_idx = len_idx + str_len;
            },
            .type_array => {
                param_idx += 1;
                if (param_idx >= params.items.len or data_idx >= data.len) {
                    const msg = try std.fmt.allocPrintSentinel(gpa, "method {} param idx {}: incomplete array type", .{ id, param_idx }, 0);
                    defer gpa.free(msg);
                    try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
                    return;
                }
                const arr_type = params.items[param_idx];
                const wire_arr_type = data[data_idx];
                if (arr_type != wire_arr_type) {
                    const msg = try std.fmt.allocPrintSentinel(gpa, "method {} param idx {}: array type mismatch", .{ id, param_idx }, 0);
                    defer gpa.free(msg);
                    try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
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
                        const msg = try std.fmt.allocPrintSentinel(gpa, "method {} param idx {}: invalid array length", .{ id, param_idx }, 0);
                        defer gpa.free(msg);
                        try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
                        return;
                    }
                }
                data_idx = len_idx;
                switch (@as(MessageMagic, @enumFromInt(arr_type))) {
                    .type_uint, .type_int, .type_f32, .type_object_id => {
                        if (data_idx + arr_len * 4 > data.len) {
                            const msg = try std.fmt.allocPrintSentinel(gpa, "method {} param idx {}: incomplete array data", .{ id, param_idx }, 0);
                            defer gpa.free(msg);
                            try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
                            return;
                        }
                        data_idx += arr_len * 4;
                    },
                    .type_varchar => {
                        var i: usize = 0;
                        while (i < arr_len) : (i += 1) {
                            if (data_idx >= data.len) {
                                const msg = try std.fmt.allocPrintSentinel(gpa, "method {} param idx {}: incomplete array element {}", .{ id, param_idx, i }, 0);
                                defer gpa.free(msg);
                                try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
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
                                    const msg = try std.fmt.allocPrintSentinel(gpa, "method {} param idx {}: invalid array element length", .{ id, param_idx }, 0);
                                    defer gpa.free(msg);
                                    try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
                                    return;
                                }
                            }
                            if (elem_len_idx + elem_len > data.len) {
                                const msg = try std.fmt.allocPrintSentinel(gpa, "method {} param idx {}: incomplete array element data", .{ id, param_idx }, 0);
                                defer gpa.free(msg);
                                try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
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
                    const msg = try std.fmt.allocPrintSentinel(gpa, "method {} param idx {}: incomplete object ID", .{ id, param_idx }, 0);
                    defer gpa.free(msg);
                    try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
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
                        const msg = try std.fmt.allocPrintSentinel(gpa, "method {} param idx {}: invalid object name length", .{ id, param_idx }, 0);
                        defer gpa.free(msg);
                        try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
                        return;
                    }
                }
                if (len_idx + name_len > data.len) {
                    const msg = try std.fmt.allocPrintSentinel(gpa, "method {} param idx {}: incomplete object name", .{ id, param_idx }, 0);
                    defer gpa.free(msg);
                    try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
                    return;
                }
                data_idx = len_idx + name_len;
            },
        }
    }

    const callback = self.vtable.getListeners(self.ptr)[id];
    var ffi_types: std.ArrayList([*c]c.ffi_type) = .empty;
    defer ffi_types.deinit(gpa);

    try ffi_types.append(gpa, &c.ffi_type_pointer);

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
        try ffi_types.append(gpa, ffi_type);
    }

    var cif: c.ffi_cif = undefined;
    if (c.ffi_prep_cif(&cif, c.FFI_DEFAULT_ABI, @intCast(ffi_types.items.len), &c.ffi_type_void, ffi_types.items.ptr) != c.FFI_OK) {
        return error.FfiFailed;
    }

    var arg_values: std.ArrayList(?*anyopaque) = .empty;
    defer arg_values.deinit(gpa);

    try arg_values.append(gpa, @constCast(&self));

    data_idx = 0;
    var fd_idx: usize = 0;

    for (params.items) |param_type| {
        const value: ?*anyopaque = switch (@as(MessageMagic, @enumFromInt(param_type))) {
            .type_uint => blk: {
                const val = std.mem.bytesToValue(u32, data[data_idx..][0..4]);
                data_idx += 4;
                const buf = try gpa.create(u32);
                buf.* = val;
                break :blk @ptrCast(buf);
            },
            .type_int => blk: {
                const val = std.mem.bytesToValue(i32, data[data_idx..][0..4]);
                data_idx += 4;
                const buf = try gpa.create(u32);
                @as(*i32, @ptrCast(buf)).* = val;
                break :blk @ptrCast(buf);
            },
            .type_f32 => blk: {
                const val = std.mem.bytesToValue(f32, data[data_idx..][0..4]);
                data_idx += 4;
                const buf = try gpa.create(u32);
                @as(*f32, @ptrCast(buf)).* = val;
                break :blk @ptrCast(buf);
            },
            .type_fd => blk: {
                const val = fds[fd_idx];
                fd_idx += 1;
                const buf = try gpa.create(u32);
                @as(*i32, @ptrCast(buf)).* = val;
                break :blk @ptrCast(buf);
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
                break :blk @ptrCast(buf.ptr);
            },
            else => null,
        };

        if (value) |v| {
            try arg_values.append(gpa, v);
        }
    }

    c.ffi_call(&cif, @ptrCast(callback), null, arg_values.items.ptr);

    for (arg_values.items[1..]) |arg| {
        if (arg) |a| {
            gpa.destroy(@as(*u32, @ptrCast(@alignCast(a))));
        }
    }
}
