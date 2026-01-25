const std = @import("std");

const meta = std.meta;
const fmt = std.fmt;
const mem = std.mem;

const Arguments = enum {
    @"-o",
    @"-i",
    @"-p",
};

pub const Protocol = struct {
    name: []const u8,
    version: u32,
};

protopath: [:0]const u8,
outpath: [:0]const u8,
protocols: []Protocol,

const Self = @This();

pub fn init(gpa: mem.Allocator) !Self {
    var protopath: ?[:0]const u8 = null;
    var outpath: ?[:0]const u8 = null;
    var protocols: std.ArrayList(Protocol) = .empty;

    var args = std.process.args();
    var index: u8 = 0;
    while (args.next()) |arg| : (index += 1) {
        if (index == 0) continue;

        if (meta.stringToEnum(Arguments, arg)) |argument| {
            switch (argument) {
                .@"-o" => {
                    outpath = args.next() orelse return error.MissingOutputPath;
                },
                .@"-i" => {
                    protopath = args.next() orelse return error.MissingInputPath;
                },
                .@"-p" => {
                    const name = args.next() orelse return error.MissingProtocolName;
                    const version = args.next() orelse return error.MissingProtocolName;
                    try protocols.append(gpa, .{
                        .name = name,
                        .version = try fmt.parseInt(u32, version, 10),
                    });
                },
            }
        } else {
            if (protopath == null) {
                protopath = arg;
            } else if (outpath == null) {
                outpath = arg;
            } else {
                return error.TooManyArguments;
            }
        }
    }

    return Self{
        .protopath = protopath orelse return error.MissingProtoPath,
        .outpath = outpath orelse return error.MissingOutPath,
        .protocols = try protocols.toOwnedSlice(gpa),
    };
}
