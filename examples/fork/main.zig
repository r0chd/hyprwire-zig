const std = @import("std");
const posix = std.posix;
const Io = std.Io;
const mem = std.mem;

const hw = @import("hyprwire");
const test_protocol = hw.proto.test_protocol_v1;

var quitt: bool = false;

const Client = struct {
    io: Io,
    objects: std.ArrayList(*test_protocol.client.MyObjectV1Object) = .empty,

    const Self = @This();

    pub fn myManagerV1Listener(
        self: *Self,
        alloc: mem.Allocator,
        proxy: *test_protocol.client.MyManagerV1Object,
        event: test_protocol.client.MyManagerV1Object.Event,
    ) void {
        _ = .{ alloc, self, proxy };
        switch (event) {
            .send_message => |message| {
                std.debug.print("Server says {s}\n", .{message.message});
            },
            .recv_message_array_uint => |message| {
                std.debug.print("Server sent uint array {any}\n", .{message.message});
            },
        }
    }

    pub fn myObjectV1Listener(
        self: *Self,
        alloc: mem.Allocator,
        proxy: *test_protocol.client.MyObjectV1Object,
        event: test_protocol.client.MyObjectV1Object.Event,
    ) void {
        switch (event) {
            .send_message => |message| {
                if (self.objects.items[0] == proxy) {
                    std.debug.print("Server says on object {s}\n", .{message.message});
                } else {
                    std.debug.print("Server says on object2 {s}\n", .{message.message});
                    self.objects.items[0].sendSendEnum(self.io, alloc, .world) catch @panic("todo");
                }
            },
        }
    }

    pub fn deinit(
        self: *Self,
        gpa: mem.Allocator,
    ) void {
        for (self.objects.items) |object| {
            object.deinit(gpa);
        }
        self.objects.deinit(gpa);
    }
};

fn runClient(io: Io, gpa: mem.Allocator, server_fd: i32) !void {
    const sock = try hw.ClientSocket.open(io, gpa, .{ .fd = server_fd });
    defer sock.deinit(io, gpa);

    sock.waitForHandshake(io, gpa) catch {
        std.debug.print("err: handshake failed\n", .{});
        return;
    };

    var impl = test_protocol.client.TestProtocolV1Impl.init(1);
    try sock.addImplementation(gpa, &impl.interface);

    std.debug.print("OK!\n", .{});

    var protocol = impl.interface.protocol();
    const SPEC = sock.getSpec(protocol.specName()) orelse {
        std.debug.print("err: test protocol unsupported\n", .{});
        return;
    };

    std.debug.print("test protocol supported at version {}. Binding.\n", .{SPEC.specVer()});

    var client = Client{ .io = io };
    defer client.deinit(gpa);

    var obj = try sock.bindProtocol(io, gpa, protocol, 1);
    defer obj.deinit(gpa);
    var manager = try test_protocol.client.MyManagerV1Object.init(
        gpa,
        .from(&client),
        &obj,
    );
    defer manager.deinit(gpa);

    std.debug.print("Bound!\n", .{});

    const pips = try Io.Threaded.pipe2(.{});
    var out: Io.File = .{ .handle = pips[1] };
    var buffer: [5]u8 = undefined;
    var writer = out.writer(io, &buffer);
    var iowriter = &writer.interface;
    try iowriter.writeAll("pipe!");
    try iowriter.flush();

    std.debug.print("Will send fd {}\n", .{pips[0]});

    try manager.sendSendMessage(io, gpa, "Hello!");
    try manager.sendSendMessageFd(io, gpa, pips[0]);
    try manager.sendSendMessageArray(io, gpa, &.{ "Hello", "via", "array!" });
    try manager.sendSendMessageArray(io, gpa, &.{});
    try manager.sendSendMessageArrayUint(io, gpa, &.{ 69, 420, 2137 });

    var object_arg = try manager.sendMakeObject(io, gpa);
    defer object_arg.deinit(gpa);
    var cobject = try test_protocol.client.MyObjectV1Object.init(
        gpa,
        .from(&client),
        &object_arg,
    );
    try client.objects.append(gpa, cobject);

    var object_arg2 = try manager.sendMakeObject(io, gpa);
    defer object_arg2.deinit(gpa);
    var cobject2 = try test_protocol.client.MyObjectV1Object.init(
        gpa,
        .from(&client),
        &object_arg2,
    );
    try client.objects.append(gpa, cobject2);

    try cobject.sendSendMessage(io, gpa, "Hello from object");
    try cobject2.sendSendMessage(io, gpa, "Hello from object2");

    while (sock.dispatchEvents(io, gpa, true)) {
        if (quitt) break;
    } else |_| {}

    try sock.roundtrip(io, gpa);
}

const Server = struct {
    alloc: mem.Allocator,
    socket: *hw.ServerSocket,
    manager: ?*test_protocol.server.MyManagerV1Object = null,
    objects: std.ArrayList(*test_protocol.server.MyObjectV1Object) = .empty,
    object_handles: std.ArrayList(hw.types.Object) = .empty,
    io: Io,

    const Self = @This();

    pub fn bind(self: *Self, object: *hw.types.Object) void {
        const manager = test_protocol.server.MyManagerV1Object.init(self.alloc, .from(self), object) catch |err|
            std.debug.panic("Error while initializing MyManagerV1Object: {s}", .{@errorName(err)});
        self.manager = manager;
    }

    pub fn myManagerV1Listener(
        self: *Self,
        alloc: mem.Allocator,
        proxy: *test_protocol.server.MyManagerV1Object,
        event: test_protocol.server.MyManagerV1Object.Event,
    ) void {
        _ = proxy;
        switch (event) {
            .send_message => {},
            .send_message_fd => {},
            .send_message_array => {},
            .send_message_array_uint => {},
            .make_object => |seq| {
                const manager = self.manager orelse return;
                const server_object = self.socket.createObject(
                    self.io,
                    alloc,
                    manager.getObject().getClient(),
                    @ptrCast(@alignCast(manager.getObject().ptr)),
                    "my_object_v1",
                    seq.seq,
                ) orelse return;

                self.object_handles.append(alloc, .from(server_object)) catch |err|
                    std.debug.panic("Error while appending object handle: {s}", .{@errorName(err)});
                const handle_ptr = &self.object_handles.items[self.object_handles.items.len - 1];
                const object = test_protocol.server.MyObjectV1Object.init(alloc, .from(self), handle_ptr) catch |err|
                    std.debug.panic("Error while initializing MyObjectV1Object: {s}", .{@errorName(err)});
                self.objects.append(alloc, object) catch |err|
                    std.debug.panic("Error while appending object: {s}", .{@errorName(err)});
            },
        }
    }

    pub fn myObjectV1Listener(
        self: *Self,
        alloc: mem.Allocator,
        proxy: *test_protocol.server.MyObjectV1Object,
        event: test_protocol.server.MyObjectV1Object.Event,
    ) void {
        _ = .{ self, alloc, proxy, event };
    }

    pub fn deinit(self: *Self, io: Io, gpa: mem.Allocator) void {
        if (self.manager) |manager| {
            self.alloc.destroy(manager.object);
            manager.deinit(gpa);
        }
        for (self.object_handles.items) |object_handle| {
            object_handle.deinit(gpa);
        }
        self.object_handles.deinit(gpa);
        for (self.objects.items) |object| {
            object.deinit(gpa);
        }
        self.objects.deinit(gpa);
        self.socket.deinit(io, gpa);
    }
};

fn runServer(io: Io, gpa: mem.Allocator, client_fd: i32) !void {
    const sock = try hw.ServerSocket.open(io, gpa, null);

    var server = Server{ .alloc = gpa, .io = io, .socket = sock };
    defer server.deinit(io, gpa);
    var impl = test_protocol.server.TestProtocolV1Impl.init(1, .from(&server));
    try sock.addImplementation(gpa, &impl.interface);

    _ = sock.addClient(io, gpa, client_fd) catch {
        std.debug.print("Failed to add clientFd to the server socket!\n", .{});
        std.process.exit(1);
    };

    while (!quitt) {
        sock.dispatchEvents(io, gpa, true) catch break;
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;

    var sock_fds: [2]i32 = undefined;
    if (posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &sock_fds) != 0) return error.Idk;

    const s = 0;
    const c = 1;
    const child = posix.system.fork();
    if (child < 0) {
        _ = posix.system.close(sock_fds[s]);
        _ = posix.system.close(sock_fds[c]);
        std.debug.print("Failed to fork\n", .{});
    } else if (child == 0) {
        _ = posix.system.close(sock_fds[s]);
        var child_io_backend = Io.Threaded.init(gpa, .{
            .argv0 = .{},
            .environ = init.minimal.environ,
        });
        const child_io = child_io_backend.io();
        try runClient(child_io, gpa, sock_fds[c]);
    } else {
        _ = posix.system.close(sock_fds[c]);
        var parent_io_backend = Io.Threaded.init(gpa, .{
            .argv0 = .{},
            .environ = init.minimal.environ,
        });
        const parent_io = parent_io_backend.io();
        try runServer(parent_io, gpa, sock_fds[s]);
    }
}
