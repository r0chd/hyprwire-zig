const Trait = @import("trait").Trait;
const std = @import("std");

const mem = std.mem;

pub const WireObject = @import("WireObject.zig").WireObject;
pub const Object = @import("Object.zig").Object;
pub const server_impl = @import("server_impl.zig");
pub const client_impl = @import("client_impl.zig");
pub const called = @import("WireObject.zig").called;

pub const Method = struct {
    idx: u32 = 0,
    params: []const u8,
    returns_type: []const u8 = "",
    since: u32 = 0,
};

pub const ProtocolObjectSpec = Trait(.{
    .objectName = fn () []const u8,
    .c2s = fn () []const Method,
    .s2c = fn () []const Method,
}, null);

pub const ProtocolSpec = Trait(.{
    .specName = fn () []const u8,
    .specVer = fn () u32,
    .objects = fn () []const ProtocolObjectSpec,
    .deinit = fn (mem.Allocator) void,
}, null);

pub const Args = struct {
    args: []const Arg,
    idx: usize = 0,

    const Self = @This();

    pub fn init(gpa: mem.Allocator, args: anytype) !Self {
        const ArgsType = @TypeOf(args);
        const args_type_info = @typeInfo(ArgsType);
        if (args_type_info != .@"struct") {
            @compileError("expected tuple or struct argument, found " ++ @typeName(ArgsType));
        }

        const fields_info = args_type_info.@"struct".fields;
        if (fields_info.len > 32) {
            @compileError("32 arguments max are supported per format call");
        }

        var args_list: std.ArrayList(Arg) = try .initCapacity(gpa, fields_info.len);

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

        return .{ .args = try args_list.toOwnedSlice(gpa) };
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

const Arg = union(enum) {
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
