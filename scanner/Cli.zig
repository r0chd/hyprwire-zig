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

protopaths: []const [:0]const u8,
outpath: [:0]const u8,
protocols: []Protocol,

const Self = @This();

pub fn init(gpa: mem.Allocator, args: std.process.Args) !Self {
    var protopaths: std.ArrayList([:0]const u8) = .empty;
    var outpath: ?[:0]const u8 = null;
    var protocols: std.ArrayList(Protocol) = .empty;

    var iter = args.iterate();
    _ = iter.next();
    while (iter.next()) |arg| {
        if (meta.stringToEnum(Arguments, arg)) |argument| {
            switch (argument) {
                .@"-o" => {
                    outpath = iter.next() orelse return error.MissingOutputPath;
                },
                .@"-i" => {
                    const path = iter.next() orelse return error.MissingInputPath;
                    try protopaths.append(gpa, path);
                },
                .@"-p" => {
                    const name = iter.next() orelse return error.MissingProtocolName;
                    const version = iter.next() orelse return error.MissingProtocolName;
                    try protocols.append(gpa, .{
                        .name = name,
                        .version = try fmt.parseInt(u32, version, 10),
                    });
                },
            }
        } else {
            if (outpath == null) {
                outpath = arg;
            } else {
                return error.TooManyArguments;
            }
        }
    }

    return Self{
        .protopaths = try protopaths.toOwnedSlice(gpa),
        .outpath = outpath orelse return error.MissingOutPath,
        .protocols = try protocols.toOwnedSlice(gpa),
    };
}
