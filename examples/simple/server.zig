const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const fmt = std.fmt;

const hw = @import("hyprwire");
const test_protocol = hw.proto.test_protocol_v1.server;

const Server = struct {
    alloc: mem.Allocator,
    socket: *hw.ServerSocket,
    manager: ?*test_protocol.MyManagerV1Object = null,
    object: ?*test_protocol.MyObjectV1Object = null,
    object_handle: ?hw.types.Object = null,

    const Self = @This();

    pub fn bind(self: *Self, object: *hw.types.Object) void {
        std.debug.print("Object bound XD\n", .{});

        var manager = test_protocol.MyManagerV1Object.init(self.alloc, test_protocol.MyManagerV1Object.Listener.from(self), object) catch return;
        manager.sendSendMessage(self.alloc, "Hello object") catch {};

        self.manager = manager;
    }

    pub fn myManagerV1Listener(self: *Self, alloc: mem.Allocator, event: test_protocol.MyManagerV1Object.Event) void {
        switch (event) {
            .send_message => |message| {
                std.debug.print("Recvd message: {s}\n", .{message.message});
            },
            .send_message_fd => |message| {
                var buf: [5]u8 = undefined;
                _ = posix.read(message.message, &buf) catch {};
                std.debug.print("Recvd fd {} with data: {s}\n", .{ message.message, buf });
            },
            .send_message_array => |message| {
                var str: std.ArrayList(u8) = .empty;

                for (message.message) |msg| {
                    str.print(alloc, "{s}, ", .{msg}) catch unreachable;
                }
                if (str.items.len > 1) {
                    _ = str.pop();
                    _ = str.pop();
                }
                std.debug.print("Got array message: {s}\n", .{str.items});
            },
            .send_message_array_uint => |message| {
                var str: std.ArrayList(u8) = .empty;

                for (message.message) |msg| {
                    str.print(alloc, "{}, ", .{msg}) catch unreachable;
                }
                if (str.items.len > 1) {
                    _ = str.pop();
                    _ = str.pop();
                }
                std.debug.print("Got uint array message: {s}\n", .{str.items});
            },
            .make_object => |seq| {
                const manager = self.manager orelse return;
                const server_object = self.socket.createObject(
                    self.alloc,
                    manager.getObject().vtable.getClient(manager.getObject().ptr),
                    @ptrCast(@alignCast(manager.getObject().ptr)),
                    "my_object_v1",
                    seq.seq,
                ).?;

                self.object_handle = hw.types.Object.from(server_object);

                var object = test_protocol.MyObjectV1Object.init(self.alloc, test_protocol.MyObjectV1Object.Listener.from(self), &self.object_handle.?) catch return;
                object.sendSendMessage(alloc, "Hello object") catch return;
                self.object = object;
            },
        }
    }

    pub fn myObjectV1Listener(self: *Self, alloc: mem.Allocator, event: test_protocol.MyObjectV1Object.Event) void {
        const obj = self.object orelse return;
        switch (event) {
            .send_message => |message| {
                std.debug.print("Object says hello: {s}\n", .{message.message});
            },
            .send_enum => |message| {
                std.debug.print("Object sent enum: {}\n", .{message.message});

                std.debug.print("Erroring out the client!\n", .{});

                obj.@"error"(alloc, @intFromEnum(message.message), "Important error occurred!");
            },
            .destroy => {},
        }
    }

    pub fn deinit(self: *Self) void {
        if (self.manager) |manager| {
            self.alloc.destroy(manager.object);
            manager.deinit(self.alloc);
        }
        if (self.object) |object| {
            object.deinit(self.alloc);
        }
        self.socket.deinit(self.alloc);
    }
};

fn socketPath(alloc: mem.Allocator, environ: *std.process.Environ.Map) ![:0]u8 {
    const runtime_dir = environ.get("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntimeDir;
    return try fmt.allocPrintSentinel(alloc, "{s}/test-hw.sock", .{runtime_dir}, 0);
}

pub fn main(init: std.process.Init) !void {
    const socket_path = try socketPath(init.gpa, init.environ_map);
    defer init.gpa.free(socket_path);

    const socket = try hw.ServerSocket.open(init.gpa, init.io, socket_path);
    var server = Server{ .alloc = init.gpa, .socket = socket };
    defer server.deinit();

    const spec = test_protocol.TestProtocolV1Impl.init(1, test_protocol.TestProtocolV1Listener.from(&server));
    const pro = hw.types.server.ProtocolImplementation.from(&spec);
    try socket.addImplementation(init.gpa, pro);

    while (socket.dispatchEvents(init.gpa, true) catch false) {}
}
