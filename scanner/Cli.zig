const std = @import("std");
const build_options = @import("build_options");

const meta = std.meta;
const version = build_options.version;

const Arguments = enum {
    @"-v",
    @"--version",
    @"-c",
    @"--client",
};

const Role = enum {
    client,
    server,
};

protopath: [:0]const u8,
outpath: [:0]const u8,
role: Role,

const Self = @This();

pub fn init() !Self {
    var protopath: ?[:0]const u8 = null;
    var outpath: ?[:0]const u8 = null;
    var role: Role = .server;

    var args = std.process.args();
    var index: u8 = 0;
    while (args.next()) |arg| : (index += 1) {
        if (index == 0) continue;

        if (meta.stringToEnum(Arguments, arg)) |argument| {
            switch (argument) {
                .@"--version", .@"-v" => {
                    std.debug.print("{s}", .{version});
                    std.process.exit(0);
                },
                .@"--client", .@"-c" => role = .client,
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
        .role = role,
    };
}
