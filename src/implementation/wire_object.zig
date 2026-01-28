const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;

const helpers = @import("helpers");
const hyprwire = @import("hyprwire");
const Trait = @import("trait").Trait;

const message_parser = @import("../message/MessageParser.zig");
const Message = @import("../message/messages/root.zig").Message;
const MessageMagic = @import("../types/MessageMagic.zig").MessageMagic;
const Object = @import("object.zig").Object;
const types = @import("types.zig");
const Method = types.Method;

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("ffi.h");
});
const log = std.log.scoped(.hw);

pub const WireObject = Trait(.{
    .getVersion = fn () u32,
    .getListeners = fn () []*anyopaque,
    .methodsOut = fn () []const Method,
    .methodsIn = fn () []const Method,
    .errd = fn () void,
    .sendMessage = fn (std.Io, mem.Allocator, Message) anyerror!void,
    .server = fn () bool,
    .getId = fn () u32,
}, .{Object});

pub const Error = error{
    InvalidMethod,
    ProtocolVersionTooLow,
    InvalidParameter,
    IncorrectParamIdx,
    DemarshalingFailed,
    Unimplemented,
};

pub fn called(
    self: WireObject,
    io: std.Io,
    gpa: mem.Allocator,
    id: u32,
    data: []const u8,
    fds: []const i32,
) (Error || mem.Allocator.Error)!void {
    // Too much shit to keep track of
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var buffer: [65_536]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var fallback_allocator = hyprwire.FallbackAllocator{
        .fba = &fba,
        .fixed = fba.allocator(),
        .fallback = arena.allocator(),
    };

    const methods = self.vtable.methodsIn(self.ptr);

    if (methods.len <= id) {
        const msg = try std.fmt.allocPrintSentinel(fallback_allocator.allocator(), "invalid method {} for object {}", .{ id, self.vtable.getId(self.ptr) }, 0);
        log.debug("core protocol error: {s}", .{msg});
        self.vtable.@"error"(self.ptr, io, fallback_allocator.allocator(), self.vtable.getId(self.ptr), msg);
        return Error.InvalidMethod;
    }

    if (self.vtable.getListeners(self.ptr).len <= id) {
        return;
    }

    const method = methods[id];
    var params: std.ArrayList(u8) = .empty;

    if (method.returns_type.len > 0) {
        try params.append(fallback_allocator.allocator(), @intFromEnum(MessageMagic.type_seq));
    }

    try params.appendSlice(fallback_allocator.allocator(), method.params);

    if (method.since > self.vtable.getVersion(self.ptr)) {
        const msg = try std.fmt.allocPrintSentinel(fallback_allocator.allocator(), "method {} since {} but has {}", .{ id, method.since, self.vtable.getVersion(self.ptr) }, 0);
        log.debug("core protocol error: {s}", .{msg});
        self.vtable.@"error"(self.ptr, io, fallback_allocator.allocator(), self.vtable.getId(self.ptr), msg);
        return Error.ProtocolVersionTooLow;
    }

    var ffi_types: std.ArrayList(*c.ffi_type) = .empty;
    try ffi_types.append(fallback_allocator.allocator(), &c.ffi_type_pointer);

    var data_idx: usize = 0;
    var i: usize = 0;
    while (i < params.items.len) : (i += 1) {
        const param: MessageMagic = @enumFromInt(params.items[i]);
        const wire_param: MessageMagic = @enumFromInt(data[data_idx]);

        if (param != wire_param) {
            const msg = try std.fmt.allocPrintSentinel(fallback_allocator.allocator(), "method {} param idx {} should be {s} but was {s}", .{ id, i, @tagName(param), @tagName(wire_param) }, 0);
            log.debug("core protocol error: {s}", .{msg});
            self.vtable.@"error"(self.ptr, io, fallback_allocator.allocator(), self.vtable.getId(self.ptr), msg);
            return Error.InvalidParameter;
        }

        const ffi_type = helpers.ffiTypeFrom(param);
        try ffi_types.append(fallback_allocator.allocator(), @ptrCast(ffi_type));

        switch (param) {
            .end => i += 1, // BUG if this happens or malformed message
            .type_fd => data_idx += 1,
            .type_uint, .type_f32, .type_int, .type_object, .type_seq => data_idx += 5,
            .type_varchar => {
                const a, const b = message_parser.parseVarInt(data[data_idx + 1 ..], 0);
                data_idx += a + b + 1;
                break;
            },
            .type_array => {
                i += 1;
                const arr_type: MessageMagic = @enumFromInt(params.items[i]);
                const wire_type: MessageMagic = @enumFromInt(data[data_idx + 1]);

                if (arr_type != wire_type) {
                    // raise protocol error
                    const msg = try fmt.allocPrintSentinel(fallback_allocator.allocator(), "method {} param idx {} should be {s} but was {s}", .{ id, i, @tagName(param), @tagName(wire_param) }, 0);
                    log.debug("core protocol error: {s}", .{msg});
                    self.vtable.@"error"(self.ptr, io, fallback_allocator.allocator(), self.vtable.getId(self.ptr), msg);
                    return Error.IncorrectParamIdx;
                }

                const arr_len, const len_len = message_parser.parseVarInt(data[data_idx + 2 ..], 0);
                var arr_message_len = 2 + len_len;

                const ffi_type_2 = helpers.ffiTypeFrom(MessageMagic.type_uint);
                try ffi_types.append(fallback_allocator.allocator(), @ptrCast(ffi_type_2));

                switch (arr_type) {
                    .type_uint, .type_f32, .type_int, .type_object, .type_seq => arr_message_len += 4 * arr_len,
                    .type_varchar => {
                        for (0..arr_len) |_| {
                            if (data_idx + arr_message_len > data.len) {
                                const msg = "failed demarshaling array message";
                                log.debug("core protocol error: {s}", .{msg});
                                self.vtable.@"error"(self.ptr, io, fallback_allocator.allocator(), self.vtable.getId(self.ptr), msg);
                                return Error.DemarshalingFailed;
                            }

                            const str_len, const str_len_len = message_parser.parseVarInt(data[data_idx + arr_message_len ..], 0);
                            arr_message_len += str_len + str_len_len;
                        }
                    },
                    .type_fd => {},
                    else => {
                        const msg = "failed demarshaling array message";
                        log.debug("core protocol error: {s}", .{msg});
                        self.vtable.@"error"(self.ptr, io, fallback_allocator.allocator(), self.vtable.getId(self.ptr), msg);
                        return Error.DemarshalingFailed;
                    },
                }

                data_idx += arr_message_len;
            },
            .type_object_id => {
                const msg = "object type is not impld";
                log.debug("core protocol error: {s}", .{msg});
                self.vtable.@"error"(self.ptr, io, fallback_allocator.allocator(), self.vtable.getId(self.ptr), msg);
                return Error.Unimplemented;
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

    try avalues.ensureTotalCapacity(fallback_allocator.allocator(), ffi_types.items.len);
    // First argument is always the object pointer expected by the listener.
    // libffi expects each entry in avalues to point to the argument value, so
    // we must store a pointer-to-pointer for the object.
    const obj = try fallback_allocator.allocator().create(Object);
    obj.* = self.asEmbed(Object);

    const obj_ptr = try fallback_allocator.allocator().create(*Object);
    obj_ptr.* = obj;

    // Second argument which is always a fallback allocator
    try avalues.append(fallback_allocator.allocator(), @ptrCast(obj_ptr));
    var strings: std.ArrayList([]const u8) = .empty;
    var fd_no: usize = 0;

    i = 0;
    while (i < data.len) : (i += 1) {
        var buf: ?*anyopaque = null;
        const param: MessageMagic = @enumFromInt(data[i]);

        switch (param) {
            .end => break,
            .type_uint => {
                const p = try fallback_allocator.allocator().create(u32);
                @memcpy(std.mem.asBytes(p), data[i + 1 .. i + 1 + @sizeOf(u32)]);
                buf = p;
                i += @sizeOf(u32);
            },
            .type_f32 => {
                const p = try fallback_allocator.allocator().create(f32);
                @memcpy(std.mem.asBytes(p), data[i + 1 .. i + 1 + @sizeOf(f32)]);
                buf = p;
                i += @sizeOf(f32);
            },
            .type_int => {
                const p = try fallback_allocator.allocator().create(i32);
                @memcpy(std.mem.asBytes(p), data[i + 1 .. i + 1 + @sizeOf(i32)]);
                buf = p;
                i += @sizeOf(i32);
            },
            .type_object => {
                const p = try fallback_allocator.allocator().create(u32);
                @memcpy(std.mem.asBytes(p), data[i + 1 .. i + 1 + @sizeOf(u32)]);
                buf = p;
                i += @sizeOf(u32);
            },
            .type_seq => {
                const p = try fallback_allocator.allocator().create(u32);
                @memcpy(std.mem.asBytes(p), data[i + 1 .. i + 1 + @sizeOf(u32)]);
                buf = p;
                i += @sizeOf(u32);
            },
            .type_varchar => {
                const str_len, const len = message_parser.parseVarInt(data[i + 1 ..], 0);

                const str_bytes = data[i + 1 + len .. i + 1 + len + str_len];
                const owned_str = try fallback_allocator.allocator().allocSentinel(u8, str_bytes.len, 0);
                @memcpy(owned_str, str_bytes);

                const slot = try fallback_allocator.allocator().create([*:0]const u8);
                slot.* = @ptrCast(owned_str.ptr);
                buf = @ptrCast(slot);

                i += str_len + len;
            },
            .type_array => {
                const arr_type: MessageMagic = @enumFromInt(data[i + 1]);
                const arr_len, const len_len = message_parser.parseVarInt(data[i + 2 ..], 0);
                var arr_message_len: usize = 2 + len_len;

                switch (arr_type) {
                    .type_uint, .type_f32, .type_int, .type_object, .type_seq => {
                        const data_ptr = try fallback_allocator.allocator().alloc(u32, if (arr_len == 0) 1 else arr_len);
                        const data_slot = try fallback_allocator.allocator().create([*]u32);
                        data_slot.* = data_ptr.ptr;
                        const size_slot = try fallback_allocator.allocator().create(u32);
                        size_slot.* = @intCast(arr_len);

                        try avalues.append(fallback_allocator.allocator(), @ptrCast(data_slot));
                        try avalues.append(fallback_allocator.allocator(), @ptrCast(size_slot));
                        try other_buffers.append(fallback_allocator.allocator(), @ptrCast(data_ptr.ptr));

                        for (0..arr_len) |j| {
                            @memcpy(std.mem.asBytes(&data_ptr[j]), data[i + arr_message_len .. i + arr_message_len + @sizeOf(u32)]);
                            arr_message_len += @sizeOf(u32);
                        }
                    },
                    .type_varchar => {
                        const data_ptr = try fallback_allocator.allocator().alloc(?[*:0]const u8, if (arr_len == 0) 1 else arr_len);
                        const data_slot = try fallback_allocator.allocator().create([*]?[*:0]const u8);
                        data_slot.* = data_ptr.ptr;
                        const size_slot = try fallback_allocator.allocator().create(u32);
                        size_slot.* = @intCast(arr_len);

                        try avalues.append(fallback_allocator.allocator(), @ptrCast(data_slot));
                        try avalues.append(fallback_allocator.allocator(), @ptrCast(size_slot));
                        try other_buffers.append(fallback_allocator.allocator(), @ptrCast(data_ptr.ptr));

                        for (0..arr_len) |j| {
                            const str_len, const strlen_len = message_parser.parseVarInt(data[i + arr_message_len ..], 0);
                            const str_data = data[i + arr_message_len + strlen_len .. i + arr_message_len + strlen_len + str_len];

                            const owned_str = try fallback_allocator.allocator().allocSentinel(u8, str_data.len, 0);
                            @memcpy(owned_str, str_data);
                            try strings.append(fallback_allocator.allocator(), owned_str);

                            data_ptr[j] = @ptrCast(owned_str.ptr);

                            arr_message_len += strlen_len + str_len;
                        }
                    },
                    .type_fd => {
                        const data_ptr = try fallback_allocator.allocator().alloc(i32, if (arr_len == 0) 1 else arr_len);
                        const data_slot = try fallback_allocator.allocator().create([*]i32);
                        data_slot.* = data_ptr.ptr;
                        const size_slot = try fallback_allocator.allocator().create(u32);
                        size_slot.* = @intCast(arr_len);

                        try avalues.append(fallback_allocator.allocator(), @ptrCast(data_slot));
                        try avalues.append(fallback_allocator.allocator(), @ptrCast(size_slot));
                        try other_buffers.append(fallback_allocator.allocator(), @ptrCast(data_ptr.ptr));

                        for (0..arr_len) |j| {
                            if (fd_no >= fds.len) {
                                const msg = "failed demarshaling array message";
                                log.debug("core protocol error: {s}", .{msg});
                                self.vtable.@"error"(self.ptr, io, fallback_allocator.allocator(), self.vtable.getId(self.ptr), msg);
                                return Error.DemarshalingFailed;
                            }
                            data_ptr[j] = fds[fd_no];
                            fd_no += 1;
                        }
                    },
                    else => {
                        const msg = "failed demarshaling array message";
                        log.debug("core protocol error: {s}", .{msg});
                        self.vtable.@"error"(self.ptr, io, fallback_allocator.allocator(), self.vtable.getId(self.ptr), msg);
                        return Error.DemarshalingFailed;
                    },
                }

                i += arr_message_len - 1; // For loop does += 1
            },
            .type_object_id => {
                const msg = "object type is not impld";
                log.debug("core protocol error: {s}", .{msg});
                self.vtable.@"error"(self.ptr, io, fallback_allocator.allocator(), self.vtable.getId(self.ptr), msg);
                return Error.Unimplemented;
            },
            .type_fd => {
                const p = try fallback_allocator.allocator().create(i32);
                p.* = fds[fd_no];
                fd_no += 1;

                buf = p;
            },
        }

        if (buf) |b| {
            try avalues.append(fallback_allocator.allocator(), b);
        }
    }

    const listener = self.vtable.getListeners(self.ptr)[id];
    c.ffi_call(&cif, @ptrCast(listener), null, avalues.items.ptr);
}

test {
    std.testing.refAllDecls(@This());
}
