const std = @import("std");

const meta = std.meta;

const Arguments = enum {
    @"-v",
    @"--version",
    @"-o",
    @"-i",
};

protopath: [:0]const u8,
outpath: [:0]const u8,

const Self = @This();

pub fn init() !Self {
    var protopath: ?[:0]const u8 = null;
    var outpath: ?[:0]const u8 = null;

    var args = std.process.args();
    var index: u8 = 0;
    while (args.next()) |arg| : (index += 1) {
        if (index == 0) continue;

        if (meta.stringToEnum(Arguments, arg)) |argument| {
            switch (argument) {
                .@"--version", .@"-v" => {
                    std.debug.print("hyprwire scanner\n", .{});
                    std.process.exit(0);
                },
                .@"-o" => {
                    outpath = args.next() orelse return error.MissingOutputPath;
                },
                .@"-i" => {
                    protopath = args.next() orelse return error.MissingInputPath;
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
    };
}
