const std = @import("std");
const mem = std.mem;

pub const client = @import("client_impl.zig");
pub const Object = @import("Object.zig");
pub const server = @import("server_impl.zig");
pub const WireObject = @import("WireObject.zig");

pub const MessageMagic = enum(u8) {
    /// Signifies an end of a message
    end = 0x0,

    /// Primitive type identifiers
    type_uint = 0x10,
    type_int = 0x11,
    type_f32 = 0x12,
    type_seq = 0x13,
    type_object_id = 0x14,

    /// Variable length types
    /// [magic : 1B][len : VLQ][data : len B]
    type_varchar = 0x20,

    /// [magic : 1B][type : 1B][n_els : VLQ]{ [data...] }
    type_array = 0x21,

    /// [magic : 1B][id : UINT][name_len : VLQ][object name ...]
    type_object = 0x22,

    /// Special types
    /// FD has size 0. It's passed via control.
    type_fd = 0x40,
};

pub const Method = struct {
    idx: u32 = 0,
    params: []const u8,
    returns_type: []const u8 = "",
    since: u32 = 0,
};

pub const ProtocolObjectSpec = struct {
    objectNameFn: *const fn (*const Self) []const u8,
    c2sFn: *const fn (*const Self) []const Method,
    s2cFn: *const fn (*const Self) []const Method,

    const Self = @This();

    pub fn objectName(self: *const Self) []const u8 {
        return self.objectNameFn(self);
    }

    pub fn c2s(self: *const Self) []const Method {
        return self.c2sFn(self);
    }

    pub fn s2c(self: *const Self) []const Method {
        return self.s2cFn(self);
    }
};

pub const ProtocolSpec = struct {
    specNameFn: *const fn (*const Self) []const u8,
    specVerFn: *const fn (*const Self) u32,
    objectsFn: *const fn (*const Self) []const *const ProtocolObjectSpec,
    deinitFn: *const fn (*Self, mem.Allocator) void,

    const Self = @This();

    pub fn specName(self: *const Self) []const u8 {
        return self.specNameFn(self);
    }

    pub fn specVer(self: *const Self) u32 {
        return self.specVerFn(self);
    }

    pub fn objects(self: *const Self) []const *const ProtocolObjectSpec {
        return self.objectsFn(self);
    }

    pub fn deinit(self: *Self, gpa: mem.Allocator) void {
        return self.deinitFn(self, gpa);
    }
};

pub const Args = struct {
    args: []const Arg,
    idx: usize = 0,

    const Self = @This();

    pub fn init(buffer: []Arg, args: anytype) Self {
        const ArgsType = @TypeOf(args);
        const args_type_info = @typeInfo(ArgsType);
        if (args_type_info != .@"struct") {
            @compileError("expected tuple or struct argument, found " ++ @typeName(ArgsType));
        }

        const fields_info = args_type_info.@"struct".fields;
        if (fields_info.len > 32) {
            @compileError("32 arguments max are supported per format call");
        }

        var args_list: std.ArrayList(Arg) = .initBuffer(buffer);

        inline for (fields_info) |field| {
            const field_value = @field(args, field.name);
            const field_type = field.type;

            if (@typeInfo(field_type) == .@"enum") {
                const tag_int: u32 = @intCast(@intFromEnum(field_value));
                args_list.appendAssumeCapacity(.{ .uint = tag_int });
            } else {
                const arg = switch (field_type) {
                    u32 => Arg{ .uint = field_value },
                    i32 => Arg{ .int = field_value },
                    f32 => Arg{ .f32 = field_value },
                    [:0]const u8 => Arg{ .varchar = field_value },
                    []const u32 => Arg{ .array_uint = field_value },
                    []const i32 => Arg{ .array_int = field_value },
                    []const f32 => Arg{ .array_f32 = field_value },
                    []const [:0]const u8 => Arg{ .array_varchar = field_value },
                    else => @compileError("unsupported type for Arg: " ++ @typeName(field_type)),
                };
                args_list.appendAssumeCapacity(arg);
            }
        }

        return .{ .args = args_list.items };
    }

    pub fn deinit(self: *Self, gpa: mem.Allocator) void {
        gpa.free(self.args);
    }

    pub fn next(self: *Self) ?Arg {
        if (self.idx >= self.args.len) return null;
        const arg = self.args[self.idx];
        self.idx += 1;
        return arg;
    }
};

pub const Arg = union(enum) {
    uint: u32,
    int: i32,
    f32: f32,
    object: u32,
    seq: u32,
    varchar: [:0]const u8,
    fd: i32,

    array_uint: []const u32,
    array_int: []const i32,
    array_f32: []const f32,
    array_object: []const u32,
    array_seq: []const u32,
    array_varchar: []const [:0]const u8,

    pub fn get(self: Arg, comptime T: type) ?T {
        if (@typeInfo(T) == .@"enum") {
            const tag_type = @typeInfo(T).@"enum".tag_type;
            const raw: u32 = switch (self) {
                .uint, .object, .seq => |v| v,
                else => return null,
            };
            const tag_val: tag_type = std.math.cast(tag_type, raw) orelse return null;
            return std.meta.intToEnum(T, tag_val) catch null;
        }

        return switch (T) {
            u32 => switch (self) {
                .uint, .object, .seq => |v| v,
                else => null,
            },
            i32 => switch (self) {
                .int, .fd => |v| v,
                else => null,
            },
            f32 => switch (self) {
                .f32 => |v| v,
                else => null,
            },
            [:0]const u8 => switch (self) {
                .varchar => |v| v,
                else => null,
            },
            []const u32 => switch (self) {
                .array_uint, .array_object, .array_seq => |v| v,
                else => null,
            },
            []const i32 => switch (self) {
                .array_int => |v| v,
                else => null,
            },
            []const f32 => switch (self) {
                .array_f32 => |v| v,
                else => null,
            },
            []const [:0]const u8 => switch (self) {
                .array_varchar => |v| v,
                else => null,
            },
            else => @compileError("unsupported Arg.get type: " ++ @typeName(T)),
        };
    }
};

test {
    std.testing.refAllDecls(@This());
}
