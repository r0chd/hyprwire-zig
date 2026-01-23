const std = @import("std");
const hw = @import("hyprwire");
const protocol_server = hw.proto.test_protocol_v1.server;

const mem = std.mem;
const posix = std.posix;
const fmt = std.fmt;

const Server = struct {
    alloc: mem.Allocator,
    socket: *hw.ServerSocket,
    manager: ?*protocol_server.MyManagerV1Object = null,
    object: ?*protocol_server.MyObjectV1Object = null,
    object_handle: ?hw.types.Object = null,

    const Self = @This();

    pub fn bind(self: *Self, object: *hw.types.Object) void {
        std.debug.print("Object bound XD\n", .{});

        var manager = protocol_server.MyManagerV1Object.init(self.alloc, protocol_server.MyManagerV1Object.Listener.from(self), object) catch return;
        manager.sendSendMessage(self.alloc, "Hello object") catch {};

        self.manager = manager;
    }

    pub fn myManagerV1Listener(self: *Self, alloc: mem.Allocator, event: protocol_server.MyManagerV1Object.Event) void {
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

                var i: usize = 0;
                while (message.message[i] != 0) : (i += 1) {
                    str.print(alloc, "{}, ", .{message.message[i]}) catch unreachable;
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

                var object = protocol_server.MyObjectV1Object.init(self.alloc, protocol_server.MyObjectV1Object.Listener.from(self), &self.object_handle.?) catch return;
                object.sendSendMessage(self.alloc, "Hello object") catch return;
                self.object = object;
            },
        }
    }

    pub fn myObjectV1Listener(self: *Self, alloc: mem.Allocator, event: protocol_server.MyObjectV1Object.Event) void {
        _ = alloc;
        const obj = self.object orelse return;
        switch (event) {
            .send_message => |message| {
                std.debug.print("Object says hello: {s}\n", .{message.message});
            },
            .send_enum => |message| {
                std.debug.print("Object sent enum: {}\n", .{message.message});

                std.debug.print("Erroring out the client!\n", .{});

                obj.err(self.alloc, @intFromEnum(message.message), "Important error occurred!") catch return;
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

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const alloc = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("LEAK DETECTED");
    }

    const xdg_runtime_dir = posix.getenv("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntimeDir;
    const socket_path_buf = try fmt.allocPrintSentinel(alloc, "{s}/test-hw.sock", .{xdg_runtime_dir}, 0);
    defer alloc.free(socket_path_buf);

    const socket = try hw.ServerSocket.open(alloc, socket_path_buf);
    var server = Server{ .alloc = alloc, .socket = socket };
    defer server.deinit();

    const spec = protocol_server.TestProtocolV1Impl.init(1, protocol_server.TestProtocolV1Listener.from(&server));
    const pro = hw.types.server.ProtocolImplementation.from(&spec);
    try socket.addImplementation(alloc, pro);

    while (socket.dispatchEvents(alloc, true) catch false) {}
}
