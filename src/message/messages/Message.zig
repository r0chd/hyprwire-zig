const std = @import("std");

const mem = std.mem;

const MessageType = @import("../MessageType.zig").MessageType;
const MessageMagic = @import("../../types/MessageMagic.zig").MessageMagic;

data: []const u8 = undefined,
message_type: MessageType = .invalid,
len: usize = 0,

const Self = @This();

pub fn parseData(self: *const Self, gpa: mem.Allocator) ![]const u8 {
    var result = std.ArrayList(u8).initCapacity(gpa, 64) catch return error.OutOfMemory;
    defer result.deinit(gpa);
    try result.writer(gpa).print("{s} ( ", .{@tagName(self.message_type)});

    var needle: usize = 1;
    while (needle < self.data.len) {
        switch (@as(MessageMagic, @enumFromInt(self.data[needle]))) {
            .end => {
                break;
            },
            .type_seq => {
                const value: *const u32 = @ptrCast(@alignCast(&self.data[needle]));
                try result.writer(gpa).print("seq: {}", .{value.*});
                needle += 4;
                break;
            },
            .type_uint => {
                const value: *const u32 = @ptrCast(@alignCast(&self.data[needle]));
                try result.writer(gpa).print("{}", .{value.*});
                needle += 4;
                break;
            },
            .type_int => {
                const value: *const i32 = @ptrCast(@alignCast(&self.data[needle]));
                try result.writer(gpa).print("{}", .{value.*});
                needle += 4;
                break;
            },
            .type_f32 => {
                const value: *const f32 = @ptrCast(@alignCast(&self.data[needle]));
                try result.writer(gpa).print("{}", .{value.*});
                needle += 4;
                break;
            },
            // TODO:
            .type_varchar => {
                break;
            },
            .type_array => {
                break;
            },
            .type_object => {
                break;
            },
            .type_fd => {
                break;
            },
            else => {},
        }
    }
    try result.append(gpa, ')');
    return result.toOwnedSlice(gpa);
}

pub fn CheckTrait(comptime T: type) void {
    if (!@hasField(T, "base")) {
        @compileError("Required field not found: base");
    }

    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("T must be a struct");
    }

    const BaseType = @TypeOf(@field(@as(T, undefined), "base"));
    if (!@hasField(BaseType, "data")) @compileError("Required field not found: base.data");
    if (!@hasField(BaseType, "message_type")) @compileError("Required field not found: base.message_type");
    if (!@hasField(BaseType, "len")) @compileError("Required field not found: base.len");

    if (!@hasDecl(BaseType, "parseData")) @compileError("Required method not found: base.parseData");
    if (!@hasDecl(T, "fds")) @compileError("Required method not found: fds");
}
