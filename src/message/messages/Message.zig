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
                const value = std.mem.readInt(u32, self.data[needle + 1 .. needle + 5][0..4], .little);
                try result.writer(gpa).print("seq: {}", .{value});
                needle += 5;
                break;
            },
            .type_uint => {
                const value = std.mem.readInt(u32, self.data[needle + 1 .. needle + 5][0..4], .little);
                try result.writer(gpa).print("{}", .{value});
                needle += 5;
                break;
            },
            .type_int => {
                const value = std.mem.readInt(i32, self.data[needle + 1 .. needle + 5][0..4], .little);
                try result.writer(gpa).print("{}", .{value});
                needle += 5;
                break;
            },
            .type_f32 => {
                const int_value = std.mem.readInt(u32, self.data[needle + 1 .. needle + 5][0..4], .little);
                const value: f32 = @bitCast(int_value);
                try result.writer(gpa).print("{}", .{value});
                needle += 5;
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
            else => {
                needle += 1;
            },
        }
    }
    try result.append(gpa, ')');
    return result.toOwnedSlice(gpa);
}
