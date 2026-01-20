const std = @import("std");
const types = @import("types.zig");
const helpers = @import("helpers");
const message_parser = @import("../message/MessageParser.zig");
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("ffi.h");
});

const log = std.log.scoped(.hw);
const fmt = std.fmt;
const mem = std.mem;

const Message = @import("../message/messages/root.zig").Message;
const Object = @import("Object.zig").Object;
const Method = types.Method;
const MessageMagic = @import("../types/MessageMagic.zig").MessageMagic;
const Trait = @import("trait").Trait;

pub const WireObject = Trait(.{
    .getVersion = fn () u32,
    .getListeners = fn () []*anyopaque,
    .methodsOut = fn () []const Method,
    .methodsIn = fn () []const Method,
    .errd = fn () void,
    .sendMessage = fn (mem.Allocator, Message) anyerror!void,
    .server = fn () bool,
    .getId = fn () u32,
}, .{Object});

pub fn called(self: *WireObject, gpa: mem.Allocator, id: u32, data: []const u8, fds: []const i32) !void {
    const methods = self.vtable.methodsIn(self.ptr);

    if (methods.len <= id) {
        const msg = try std.fmt.allocPrintSentinel(gpa, "invalid method {} for object {}", .{ id, self.vtable.getId(self.ptr) }, 0);
        defer gpa.free(msg);
        try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
        return;
    }

    if (self.vtable.getListeners(self.ptr).len <= id) {
        return;
    }

    const method = methods[id];
    var params: std.ArrayList(u8) = .empty;
    defer params.deinit(gpa);

    if (method.returns_type.len > 0) {
        try params.append(gpa, @intFromEnum(MessageMagic.type_seq));
    }

    try params.appendSlice(gpa, method.params);

    if (method.since > self.vtable.getVersion(self.ptr)) {
        const msg = try std.fmt.allocPrintSentinel(gpa, "method {} since {} but has {}", .{ id, method.since, self.vtable.getVersion(self.ptr) }, 0);
        defer gpa.free(msg);
        try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
        return;
    }

    var ffi_types: std.ArrayList(*c.ffi_type) = .empty;
    defer ffi_types.deinit(gpa);
    try ffi_types.append(gpa, &c.ffi_type_pointer);

    var data_idx: usize = 0;
    var i: usize = 0;
    while (i < params.items.len) : (i += 1) {
        const param: MessageMagic = @enumFromInt(params.items[i]);
        const wire_param: MessageMagic = @enumFromInt(data[data_idx]);

        if (param != wire_param) {
            const msg = try std.fmt.allocPrintSentinel(gpa, "method {} param idx {} should be {s} but was {s}", .{ id, i, @tagName(param), @tagName(wire_param) }, 0);
            defer gpa.free(msg);
            try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
            return;
        }

        const ffi_type = helpers.ffiTypeFrom(param);
        try ffi_types.append(gpa, @ptrCast(ffi_type));

        switch (param) {
            .end => i += 1, // BUG if this happens or malformed message
            .type_fd => data_idx += 1,
            .type_uint, .type_f32, .type_int, .type_object, .type_seq => data_idx += 5,
            .type_varchar => {
                const a, const b = message_parser.parseVarInt(data[data_idx + 1 ..], 0);
                data_idx += a + b + i;
                break;
            },
            .type_array => {
                i += 1;
                const arr_type: MessageMagic = @enumFromInt(params.items[i]);
                const wire_type: MessageMagic = @enumFromInt(data[data_idx + 1]);

                if (arr_type != wire_type) {
                    // raise protocol error
                    const msg = try fmt.allocPrintSentinel(gpa, "method {} param idx {} should be {s} but was {s}", .{ id, i, @tagName(param), @tagName(wire_param) }, 0);
                    defer gpa.free(msg);
                    log.debug("core protocol error: {s}", .{msg});
                    try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
                    return;
                }

                const arr_len, const len_len = message_parser.parseVarInt(data[data_idx + 2 ..], 0);
                var arr_message_len = 2 + len_len;

                const ffi_type_2 = helpers.ffiTypeFrom(MessageMagic.type_uint);
                try ffi_types.append(gpa, @ptrCast(ffi_type_2));

                switch (arr_type) {
                    .type_uint, .type_f32, .type_int, .type_object, .type_seq => arr_message_len += 4 * arr_len,
                    .type_varchar => {
                        for (0..arr_len) |_| {
                            if (data_idx + arr_message_len > data.len) {
                                const msg = "failed demarshaling array message";
                                log.debug("core protocol error: {s}", .{msg});
                                try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
                                return;
                            }

                            const str_len, const str_len_len = message_parser.parseVarInt(data[data_idx..arr_message_len], 0);
                            arr_message_len = str_len + str_len_len;
                        }
                    },
                    else => {
                        const msg = "failed demarshaling array message";
                        log.debug("core protocol error: {s}", .{msg});
                        try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
                        return;
                    },
                }

                data_idx += arr_message_len;
            },
            .type_object_id => {
                const msg = "object type is not impld";
                log.debug("core protocol error: {s}", .{msg});
                try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
                return;
            },
        }
    }

    var cif: c.ffi_cif = undefined;
    if (c.ffi_prep_cif(&cif, c.FFI_DEFAULT_ABI, @intCast(ffi_types.items.len), @ptrCast(&c.ffi_type_void), @ptrCast(ffi_types.items)) != 0) {
        log.debug("core protocol error: ffi failed", .{});
        self.vtable.errd(self.ptr);
        return;
    }

    var avalues: std.ArrayList(?*anyopaque) = .empty;
    var other_buffers: std.ArrayList(*anyopaque) = .empty;

    try avalues.ensureTotalCapacity(gpa, ffi_types.items.len);
    // First argument is always the object pointer expected by the listener.
    // libffi expects each entry in avalues to point to the argument value, so
    // we must store a pointer-to-pointer for the object.
    const obj = try gpa.create(Object);
    obj.* = self.asEmbed(Object);
    const obj_ptr = try gpa.create(*Object);
    obj_ptr.* = obj;
    try avalues.append(gpa, @ptrCast(obj_ptr));
    var strings: std.ArrayList([]const u8) = .empty;

    var fd_no: usize = 0;

    i = 0;
    while (i < data.len) : (i += 1) {
        var buf: ?*anyopaque = null;
        const param: MessageMagic = @enumFromInt(data[i]);

        switch (param) {
            .end => break,
            .type_uint => {
                const p = try gpa.create(u32);
                @memcpy(std.mem.asBytes(p), data[i + 1 .. i + 1 + @sizeOf(u32)]);
                buf = p;
                i += @sizeOf(u32);
            },
            .type_f32 => {
                const p = try gpa.create(f32);
                @memcpy(std.mem.asBytes(p), data[i + 1 .. i + 1 + @sizeOf(f32)]);
                buf = p;
                i += @sizeOf(f32);
            },
            .type_int => {
                const p = try gpa.create(i32);
                @memcpy(std.mem.asBytes(p), data[i + 1 .. i + 1 + @sizeOf(i32)]);
                buf = p;
                i += @sizeOf(i32);
            },
            .type_object => {
                const p = try gpa.create(u32);
                @memcpy(std.mem.asBytes(p), data[i + 1 .. i + 1 + @sizeOf(u32)]);
                buf = p;
                i += @sizeOf(u32);
            },
            .type_seq => {
                const p = try gpa.create(u32);
                @memcpy(std.mem.asBytes(p), data[i + 1 .. i + 1 + @sizeOf(u32)]);
                buf = p;
                i += @sizeOf(u32);
            },
            .type_varchar => {
                const str_len, const len = message_parser.parseVarInt(data[i + 1 ..], 0);

                const str_bytes = data[i + 1 + len .. i + 1 + len + str_len];
                const owned_str = try gpa.allocSentinel(u8, str_bytes.len, 0);
                @memcpy(owned_str[0..str_bytes.len], str_bytes);

                const slot = try gpa.create([*:0]const u8);
                slot.* = @ptrCast(owned_str.ptr);

                buf = @ptrCast(slot);
                try strings.append(gpa, owned_str);

                i += str_len + len;
            },
            .type_array => {
                const arr_type: MessageMagic = @enumFromInt(data[i + 1]);
                const arr_len, const len_len = message_parser.parseVarInt(data[i + 2 ..], data.len - 1);
                var arr_message_len: usize = 2 + len_len;

                switch (arr_type) {
                    .type_seq => {
                        const data_ptr = try gpa.alloc(u32, if (arr_len == 0) 1 else arr_len);
                        const data_slot = try gpa.create([*]u32);
                        data_slot.* = data_ptr.ptr;
                        const size_slot = try gpa.create(u32);
                        size_slot.* = @intCast(arr_len);

                        try avalues.append(gpa, @ptrCast(data_slot));
                        try avalues.append(gpa, @ptrCast(size_slot));
                        try other_buffers.append(gpa, @ptrCast(data_ptr.ptr));

                        for (0..arr_len) |j| {
                            @memcpy(std.mem.asBytes(&data_ptr[j]), data[i + arr_message_len .. i + arr_message_len + 4]);
                            arr_message_len += 4;
                        }
                    },
                    .type_varchar => {
                        const data_ptr = try gpa.alloc(?[*:0]const u8, if (arr_len == 0) 1 else arr_len);
                        const data_slot = try gpa.create([*]?[*:0]const u8);
                        data_slot.* = data_ptr.ptr;
                        const size_slot = try gpa.create(u32);
                        size_slot.* = @intCast(arr_len);

                        try avalues.append(gpa, @ptrCast(data_slot));
                        try avalues.append(gpa, @ptrCast(size_slot));
                        try other_buffers.append(gpa, @ptrCast(data_ptr.ptr));

                        for (0..arr_len) |j| {
                            const str_len, const strlen_len = message_parser.parseVarInt(data[i + arr_message_len ..], data.len - i);
                            const str_data = data[i + arr_message_len + strlen_len .. i + arr_message_len + strlen_len + str_len];

                            const owned_str = try gpa.alloc(u8, str_data.len + 1);
                            @memcpy(owned_str[0..str_data.len], str_data);
                            owned_str[str_data.len] = 0; // Add null terminator
                            try strings.append(gpa, owned_str);

                            // Set pointer to null-terminated string
                            data_ptr[j] = @ptrCast(owned_str.ptr);

                            arr_message_len += strlen_len + str_len;
                        }
                    },
                    else => {
                        const msg = "failed demarshaling array message";
                        log.debug("core protocol error: {s}", .{msg});
                        try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
                        return;
                    },
                }

                i += arr_message_len - 1; // For loop does += 1
            },
            .type_object_id => {
                const msg = "object type is not impld";
                log.debug("core protocol error: {s}", .{msg});
                try self.vtable.err(self.ptr, gpa, self.vtable.getId(self.ptr), msg);
                return;
            },
            .type_fd => {
                const p = try gpa.create(i32);
                p.* = fds[fd_no];
                fd_no += 1;

                buf = p;
            },
        }

        if (buf) |b| {
            try avalues.append(gpa, b);
        }
    }

    const listener = self.vtable.getListeners(self.ptr)[id];
    c.ffi_call(&cif, @ptrCast(listener), null, avalues.items.ptr);
}
