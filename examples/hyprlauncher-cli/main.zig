const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const process = std.process;
const meta = std.meta;

const hyprwire = @import("hyprwire");
const hyprlauncher = hyprwire.proto.hyprlauncher_core.client;

const HYPRWIRE_PROTOCOL_VERSION: u32 = 1;

const Client = struct {
    const Self = @This();

    pub fn hyprlauncherCoreManagerListener(
        self: *Self,
        gpa: mem.Allocator,
        proxy: *hyprlauncher.HyprlauncherCoreManagerObject,
        event: hyprlauncher.HyprlauncherCoreManagerObject.Event,
    ) void {
        _ = .{ self, gpa, proxy, event };
    }

    pub fn hyprlauncherCoreInfoListener(
        self: *Self,
        gpa: mem.Allocator,
        proxy: *hyprlauncher.HyprlauncherCoreInfoObject,
        event: hyprlauncher.HyprlauncherCoreInfoObject.Event,
    ) void {
        switch (event) {
            .open_state => {},
            .selection_made => |selection| {
                std.debug.print("{s}\n", .{selection.selected});
            },
        }
        _ = .{ self, gpa, proxy };
    }
};

fn socketPath(alloc: mem.Allocator, environ: *process.Environ.Map) ![:0]u8 {
    const runtime_dir = environ.get("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntimeDir;
    return try fmt.allocPrintSentinel(alloc, "{s}/.hyprlauncher.sock", .{runtime_dir}, 0);
}

const Args = enum {
    @"-m",
    @"--dmenu",
    @"-o",
    @"--options",
};

const Cli = struct {
    options: []const [:0]const u8 = &.{},
    dmenu: bool = false,

    const Self = @This();

    fn init(gpa: mem.Allocator, args: process.Args) Self {
        var self = Self{};

        var iter = args.iterate();
        if (!iter.skip()) return .{};

        while (iter.next()) |arg| {
            if (meta.stringToEnum(Args, arg)) |a| {
                switch (a) {
                    .@"-m", .@"--dmenu" => {
                        self.dmenu = true;
                    },
                    .@"-o", .@"--options" => {
                        const options = iter.next() orelse {
                            std.debug.print("-o|--options: Missing argument\n", .{});
                            process.exit(1);
                        };

                        var list = std.ArrayList([:0]const u8).empty;
                        var split = mem.splitScalar(u8, options, ',');
                        while (split.next()) |option| {
                            const opt = gpa.dupeZ(u8, option) catch @panic("OOM");
                            list.append(gpa, opt) catch @panic("OOM");
                        }

                        self.options = list.toOwnedSlice(gpa) catch @panic("OOM");
                    },
                }
            } else {
                std.debug.print("Unkown argument: {s}\n", .{arg});
            }
        }

        return self;
    }

    pub fn deinit(self: *Self, gpa: mem.Allocator) void {
        for (self.options) |opt| gpa.free(opt);
        if (self.options.len > 0) gpa.free(self.options);
    }
};

pub fn main(init: process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var cli = Cli.init(gpa, init.minimal.args);
    defer cli.deinit(gpa);

    const path = try socketPath(gpa, init.environ_map);
    defer gpa.free(path);

    const socket = try hyprwire.ClientSocket.open(io, gpa, .{ .path = path });
    defer socket.deinit(io, gpa);

    const impl = hyprlauncher.HyprlauncherCoreImpl.init(HYPRWIRE_PROTOCOL_VERSION);
    try socket.addImplementation(gpa, &impl.interface);

    try socket.waitForHandshake(io, gpa);

    var client = Client{};

    var obj = try socket.bindProtocol(io, gpa, impl.interface.protocol(), HYPRWIRE_PROTOCOL_VERSION);
    defer obj.deinit(gpa);
    var manager = try hyprlauncher.HyprlauncherCoreManagerObject.init(gpa, .from(&client), obj);
    defer manager.deinit(io, gpa);

    const object = try manager.sendGetInfoObject(io, gpa);
    defer object.deinit(gpa);
    const info_object = try hyprlauncher.HyprlauncherCoreInfoObject.init(gpa, .from(&client), object);
    defer info_object.deinit(io, gpa);

    try manager.sendOpenWithOptions(io, gpa, cli.options);

    try socket.roundtrip(io, gpa);
}
