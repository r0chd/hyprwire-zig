const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;

const helpers = @import("helpers");
const hyprwire = @import("hyprwire");

const message_parser = @import("../message/MessageParser.zig");
const Message = @import("../message/messages/Message.zig");
const MessageType = @import("../message/MessageType.zig").MessageType;
const MessageMagic = @import("../types/MessageMagic.zig").MessageMagic;
const Object = @import("Object.zig");
const types = @import("types.zig");
const Method = types.Method;
const ClientObject = @import("../client/ClientObject.zig");

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("ffi.h");
});
const log = std.log.scoped(.hw);

pub const Error = error{
    InvalidMethod,
    ProtocolVersionTooLow,
    InvalidParameter,
    IncorrectParamIdx,
    DemarshalingFailed,
    Unimplemented,
};

pub const VTable = struct {
    object: Object.VTable,
    getVersion: *const fn (*anyopaque) u32,
    getListeners: *const fn (*anyopaque) []*anyopaque,
    methodsOut: *const fn (*anyopaque) []const Method,
    methodsIn: *const fn (*anyopaque) []const Method,
    errd: *const fn (*anyopaque) void,
    sendMessage: *const fn (*anyopaque, std.Io, mem.Allocator, *Message) anyerror!void,
    server: *const fn (*anyopaque) bool,
    getId: *const fn (*anyopaque) u32,
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
        if (@TypeOf(Impl.vtable) == VTable) {
            return .{
                .ptr = impl,
                .vtable = &Impl.vtable,
            };
        }
    }

    @compileError("Implementation type must have a 'vtable' declaration of type VTable");
}

pub fn asObject(self: Self) Object {
    return .{
        .ptr = self.ptr,
        .vtable = &self.vtable.object,
    };
}

// Object methods (delegated)
pub fn call(self: Self, io: std.Io, gpa: mem.Allocator, id: u32, args: *types.Args) anyerror!u32 {
    return self.vtable.object.call(self.ptr, io, gpa, id, args);
}

pub fn listen(self: Self, gpa: mem.Allocator, id: u32, callback: *const fn (*anyopaque) void) anyerror!void {
    return self.vtable.object.listen(self.ptr, gpa, id, callback);
}

pub fn clientSock(self: Self) ?*@import("../client/ClientSocket.zig") {
    return self.vtable.object.clientSock(self.ptr);
}

pub fn serverSock(self: Self) ?*@import("../server/ServerSocket.zig") {
    return self.vtable.object.serverSock(self.ptr);
}

pub fn setData(self: Self, data: *anyopaque) void {
    self.vtable.object.setData(self.ptr, data);
}

pub fn getData(self: Self) ?*anyopaque {
    return self.vtable.object.getData(self.ptr);
}

pub fn @"error"(self: Self, io: std.Io, gpa: mem.Allocator, id: u32, message: [:0]const u8) void {
    self.vtable.object.@"error"(self.ptr, io, gpa, id, message);
}

pub fn deinit(self: Self, gpa: mem.Allocator) void {
    self.vtable.object.deinit(self.ptr, gpa);
}

pub fn setOnDeinit(self: Self, cb: *const fn () void) void {
    self.vtable.object.setOnDeinit(self.ptr, cb);
}

pub fn getClient(self: Self) ?*@import("../server/ServerClient.zig") {
    return self.vtable.object.getClient(self.ptr);
}

// WireObject-specific methods
pub fn getVersion(self: Self) u32 {
    return self.vtable.getVersion(self.ptr);
}

pub fn getListeners(self: Self) []*anyopaque {
    return self.vtable.getListeners(self.ptr);
}

pub fn methodsOut(self: Self) []const Method {
    return self.vtable.methodsOut(self.ptr);
}

pub fn methodsIn(self: Self) []const Method {
    return self.vtable.methodsIn(self.ptr);
}

pub fn errd(self: Self) void {
    self.vtable.errd(self.ptr);
}

pub fn sendMessage(self: Self, io: std.Io, gpa: mem.Allocator, message: *Message) anyerror!void {
    return self.vtable.sendMessage(self.ptr, io, gpa, message);
}

pub fn server(self: Self) bool {
    return self.vtable.server(self.ptr);
}

pub fn getId(self: Self) u32 {
    return self.vtable.getId(self.ptr);
}

pub fn callMethod(self: Self, io: std.Io, gpa: mem.Allocator, id: u32, args: *types.Args) anyerror!u32 {
    const methods = self.methodsOut();
    if (methods.len <= id) {
        const msg = try fmt.allocPrintSentinel(gpa, "core protocol error: invalid method {} for object {}", .{ id, self.getId() }, 0);
        defer gpa.free(msg);
        log.debug("core protocol error: {s}", .{msg});
        self.@"error"(io, gpa, id, msg);
        return error.InvalidMethod;
    }

    const method = methods[id];
    const params = method.params;

    if (method.since > self.getVersion()) {
        const msg = try fmt.allocPrintSentinel(gpa, "method {} since {} but has {}", .{ id, method.since, self.getVersion() }, 0);
        defer gpa.free(msg);
        log.debug("core protocol error: {s}", .{msg});
        self.@"error"(io, gpa, id, msg);
        return error.ProtocolVersionTooLow;
    }

    if (method.returns_type.len > 0 and self.server()) {
        const msg = try fmt.allocPrintSentinel(gpa, "invalid method spec {} for object {} -> server cannot call returnsType methods", .{ id, self.getId() }, 0);
        defer gpa.free(msg);
        log.debug("core protocol error: {s}", .{msg});
        self.@"error"(io, gpa, id, msg);
        return error.InvalidMethod;
    }

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    var fds: std.ArrayList(i32) = .empty;
    defer fds.deinit(gpa);

    try data.append(gpa, @intFromEnum(MessageType.generic_protocol_message));
    try data.append(gpa, @intFromEnum(MessageMagic.type_object));

    var object_id_buf: [4]u8 = undefined;
    mem.writeInt(u32, &object_id_buf, self.getId(), .little);
    try data.appendSlice(gpa, &object_id_buf);

    try data.append(gpa, @intFromEnum(MessageMagic.type_uint));
    var method_id_buf: [4]u8 = undefined;
    mem.writeInt(u32, &method_id_buf, id, .little);
    try data.appendSlice(gpa, &method_id_buf);

    var return_seq: u32 = 0;

    if (method.returns_type.len > 0) {
        if (helpers.isTrace()) {
            if (self.getClient()) |client| {
                log.debug("[{} @ {}] -- call {}: returnsType has {s}", .{ client.stream.socket.handle, hyprwire.steadyMillis(), id, method.returns_type });
            }
        }

        try data.append(gpa, @intFromEnum(MessageMagic.type_seq));

        if (self.clientSock()) |client| {
            client.seq += 1;
            return_seq = client.seq;
        }

        var seq_buf: [4]u8 = undefined;
        mem.writeInt(u32, &seq_buf, return_seq, .little);
        try data.appendSlice(gpa, &seq_buf);
    }

    var i: usize = 0;
    while (i < params.len) : (i += 1) {
        const param = std.enums.fromInt(MessageMagic, params[i]) orelse return error.InvalidMessage;
        switch (param) {
            .type_uint => {
                try data.append(gpa, @intFromEnum(MessageMagic.type_uint));
                const arg = (args.next() orelse return error.InvalidMessage).get(u32) orelse return error.InvalidMessage;
                var buf: [4]u8 = undefined;
                mem.writeInt(u32, &buf, arg, .little);
                try data.appendSlice(gpa, &buf);
            },
            .type_int => {
                try data.append(gpa, @intFromEnum(MessageMagic.type_int));
                const arg = (args.next() orelse return error.InvalidMessage).get(i32) orelse return error.InvalidMessage;
                var buf: [4]u8 = undefined;
                mem.writeInt(i32, &buf, arg, .little);
                try data.appendSlice(gpa, &buf);
            },
            .type_object => {
                try data.append(gpa, @intFromEnum(MessageMagic.type_object));
                const arg = (args.next() orelse return error.InvalidMessage).get(u32) orelse return error.InvalidMessage;
                var buf: [4]u8 = undefined;
                mem.writeInt(u32, &buf, arg, .little);
                try data.appendSlice(gpa, &buf);
            },
            .type_f32 => {
                try data.append(gpa, @intFromEnum(MessageMagic.type_f32));
                const arg = (args.next() orelse return error.InvalidMessage).get(f32) orelse return error.InvalidMessage;
                const bits: u32 = @bitCast(arg);
                var buf: [4]u8 = undefined;
                mem.writeInt(u32, &buf, bits, .little);
                try data.appendSlice(gpa, &buf);
            },
            .type_varchar => {
                try data.append(gpa, @intFromEnum(MessageMagic.type_varchar));
                const str = (args.next() orelse return error.InvalidMessage).get([:0]const u8) orelse return error.InvalidMessage;
                var len_buf: [10]u8 = undefined;
                try data.appendSlice(gpa, message_parser.encodeVarInt(str.len, &len_buf));
                try data.appendSlice(gpa, str[0..str.len]);
            },
            .type_array => {
                if (i + 1 >= params.len) return error.InvalidMessage;
                const arr_type = std.enums.fromInt(MessageMagic, params[i + 1]) orelse return error.InvalidMessage;
                i += 1;

                try data.append(gpa, @intFromEnum(MessageMagic.type_array));
                try data.append(gpa, @intFromEnum(arr_type));

                switch (arr_type) {
                    .type_uint => {
                        const arr = (args.next() orelse return error.InvalidMessage).get([]const u32) orelse return error.InvalidMessage;
                        var len_buf: [10]u8 = undefined;
                        try data.appendSlice(gpa, message_parser.encodeVarInt(arr.len, &len_buf));
                        for (arr) |v| {
                            var buf: [4]u8 = undefined;
                            mem.writeInt(u32, &buf, v, .little);
                            try data.appendSlice(gpa, &buf);
                        }
                    },
                    .type_int => {
                        const arr = (args.next() orelse return error.InvalidMessage).get([]const i32) orelse return error.InvalidMessage;
                        var len_buf: [10]u8 = undefined;
                        try data.appendSlice(gpa, message_parser.encodeVarInt(arr.len, &len_buf));
                        for (arr) |v| {
                            var buf: [4]u8 = undefined;
                            mem.writeInt(i32, &buf, v, .little);
                            try data.appendSlice(gpa, &buf);
                        }
                    },
                    .type_f32 => {
                        const arr = (args.next() orelse return error.InvalidMessage).get([]const f32) orelse return error.InvalidMessage;
                        var len_buf: [10]u8 = undefined;
                        try data.appendSlice(gpa, message_parser.encodeVarInt(arr.len, &len_buf));
                        for (arr) |v| {
                            const bits: u32 = @bitCast(v);
                            var buf: [4]u8 = undefined;
                            mem.writeInt(u32, &buf, bits, .little);
                            try data.appendSlice(gpa, &buf);
                        }
                    },
                    .type_varchar => {
                        const arr = (args.next() orelse return error.InvalidMessage).get([]const [:0]const u8) orelse return error.InvalidMessage;
                        var len_buf: [10]u8 = undefined;
                        try data.appendSlice(gpa, message_parser.encodeVarInt(arr.len, &len_buf));
                        for (arr) |s| {
                            var slen_buf: [10]u8 = undefined;
                            try data.appendSlice(gpa, message_parser.encodeVarInt(s.len, &slen_buf));
                            try data.appendSlice(gpa, s[0..s.len]);
                        }
                    },
                    .type_fd => {
                        const fd_list = (args.next() orelse return error.InvalidMessage).get([]const i32) orelse return error.InvalidMessage;
                        for (fd_list) |fd| {
                            try fds.append(gpa, fd);
                        }
                        var len_buf: [10]u8 = undefined;
                        try data.appendSlice(gpa, message_parser.encodeVarInt(fd_list.len, &len_buf));
                    },
                    else => return error.InvalidMessage,
                }
            },
            .type_fd => {
                try data.append(gpa, @intFromEnum(MessageMagic.type_fd));
                const fd = (args.next() orelse return error.InvalidMessage).get(i32) orelse return error.InvalidMessage;
                try fds.append(gpa, fd);
            },
            else => {},
        }
    }

    try data.append(gpa, @intFromEnum(MessageMagic.end));

    var msg = try Message.GenericProtocolMessage.init(gpa, data.items, fds.items);

    if (self.getId() == 0 and !self.server()) {
        const self_client: *ClientObject = @ptrCast(@alignCast(self.ptr));

        if (helpers.isTrace()) {
            if (self_client.client) |client| {
                log.debug("[{} @ {}] -- call: waiting on object of type {s}", .{ client.stream.socket.handle, hyprwire.steadyMillis(), method.returns_type });
            }
        }

        msg.depends_on_seq = self_client.seq;
        if (self_client.client) |client| {
            try client.pending_outgoing.append(gpa, msg);
        }
    } else {
        try self.sendMessage(io, gpa, &msg.interface);
        msg.deinit(gpa);
        if (return_seq != 0) {
            const self_client: *ClientObject = @ptrCast(@alignCast(self.ptr));
            if (self_client.client) |client| {
                _ = try client.makeObject(gpa, self_client.protocol_name, method.returns_type, return_seq);
                return return_seq;
            }
        }
    }

    return 0;
}

pub fn called(
    self: Self,
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
    var fallback_allocator = helpers.FallbackAllocator{
        .fba = &fba,
        .fixed = fba.allocator(),
        .fallback = arena.allocator(),
    };

    const methods = self.methodsIn();

    if (methods.len <= id) {
        const msg = try std.fmt.allocPrintSentinel(fallback_allocator.allocator(), "invalid method {} for object {}", .{ id, self.getId() }, 0);
        log.debug("core protocol error: {s}", .{msg});
        self.@"error"(io, fallback_allocator.allocator(), self.getId(), msg);
        return Error.InvalidMethod;
    }

    if (self.getListeners().len <= id) {
        return;
    }

    const method = methods[id];
    var params: std.ArrayList(u8) = .empty;

    if (method.returns_type.len > 0) {
        try params.append(fallback_allocator.allocator(), @intFromEnum(MessageMagic.type_seq));
    }

    try params.appendSlice(fallback_allocator.allocator(), method.params);

    if (method.since > self.getVersion()) {
        const msg = try std.fmt.allocPrintSentinel(fallback_allocator.allocator(), "method {} since {} but has {}", .{ id, method.since, self.getVersion() }, 0);
        log.debug("core protocol error: {s}", .{msg});
        self.@"error"(io, fallback_allocator.allocator(), self.getId(), msg);
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
            self.@"error"(io, fallback_allocator.allocator(), self.getId(), msg);
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
                    self.@"error"(io, fallback_allocator.allocator(), self.getId(), msg);
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
                                self.@"error"(io, fallback_allocator.allocator(), self.getId(), msg);
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
                        self.@"error"(io, fallback_allocator.allocator(), self.getId(), msg);
                        return Error.DemarshalingFailed;
                    },
                }

                data_idx += arr_message_len;
            },
            .type_object_id => {
                const msg = "object type is not impld";
                log.debug("core protocol error: {s}", .{msg});
                self.@"error"(io, fallback_allocator.allocator(), self.getId(), msg);
                return Error.Unimplemented;
            },
        }
    }

    var cif: c.ffi_cif = undefined;
    if (c.ffi_prep_cif(&cif, c.FFI_DEFAULT_ABI, @intCast(ffi_types.items.len), @ptrCast(&c.ffi_type_void), @ptrCast(ffi_types.items)) != 0) {
        log.debug("core protocol error: ffi failed", .{});
        self.errd();
        return;
    }

    var avalues: std.ArrayList(?*anyopaque) = .empty;
    var other_buffers: std.ArrayList(*anyopaque) = .empty;

    try avalues.ensureTotalCapacity(fallback_allocator.allocator(), ffi_types.items.len);
    // First argument is always the object pointer expected by the listener.
    // libffi expects each entry in avalues to point to the argument value, so
    // we must store a pointer-to-pointer for the object.
    const obj = try fallback_allocator.allocator().create(Object);
    obj.* = self.asObject();

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
                                self.@"error"(io, fallback_allocator.allocator(), self.getId(), msg);
                                return Error.DemarshalingFailed;
                            }
                            data_ptr[j] = fds[fd_no];
                            fd_no += 1;
                        }
                    },
                    else => {
                        const msg = "failed demarshaling array message";
                        log.debug("core protocol error: {s}", .{msg});
                        self.@"error"(io, fallback_allocator.allocator(), self.getId(), msg);
                        return Error.DemarshalingFailed;
                    },
                }

                i += arr_message_len - 1; // For loop does += 1
            },
            .type_object_id => {
                const msg = "object type is not impld";
                log.debug("core protocol error: {s}", .{msg});
                self.@"error"(io, fallback_allocator.allocator(), self.getId(), msg);
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

    const listener = self.getListeners()[id];
    c.ffi_call(&cif, @ptrCast(listener), null, avalues.items.ptr);
}

test {
    std.testing.refAllDecls(@This());
}
