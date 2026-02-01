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

    var obj = try sock.bindProtocol(io, gpa, protocol, 1);
    defer obj.deinit(gpa);
    var manager = try test_protocol.client.MyManagerV1Object.init(
        gpa,
        .from(&client),
        &obj,
    );

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
    defer cobject.deinit(gpa);
    try client.objects.append(gpa, cobject);

    var object_arg2 = try manager.sendMakeObject(io, gpa);
    defer object_arg2.deinit(gpa);
    var cobject2 = try test_protocol.client.MyObjectV1Object.init(
        gpa,
        .from(&client),
        &object_arg2,
    );
    defer cobject2.deinit(gpa);
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
    io: Io,

    const Self = @This();

    pub fn bind(self: *Self, object: *hw.types.Object) void {
        _ = .{ self, object };
    }

    pub fn myManagerV1Listener(
        self: *Self,
        alloc: mem.Allocator,
        proxy: *test_protocol.MyManagerV1Object,
        event: test_protocol.MyManagerV1Object.Event,
    ) void {
        _ = .{ self, alloc, proxy, event };
    }

    pub fn myObjectV1Listener(
        self: *Self,
        alloc: mem.Allocator,
        proxy: *test_protocol.MyObjectV1Object,
        event: test_protocol.MyObjectV1Object.Event,
    ) void {
        _ = .{ self, alloc, proxy, event };
    }

    pub fn deinit(self: *Self) void {
        if (self.manager) |manager| {
            self.alloc.destroy(manager.object);
            manager.deinit(self.alloc);
        }
        if (self.object) |object| {
            object.deinit(self.alloc);
        }
        self.socket.deinit(self.io, self.alloc);
    }
};

fn runServer(io: Io, gpa: mem.Allocator, client_fd: i32) !void {
    const sock = try hw.ServerSocket.open(io, gpa, null);
    defer sock.deinit(io, gpa);

    const server = Server{ .alloc = gpa, .io = io, .socket = sock };
    var impl = test_protocol.server.TestProtocolV1Impl.init(1, .from(&server));
    try sock.addImplementation(gpa, &impl.interface);

    _ = sock.addClient(io, gpa, client_fd) catch {
        std.debug.print("Failed to add clientFd to the server socket!\n", .{});
        std.process.exit(1);
    };

    var pfd = posix.pollfd{
        .fd = try sock.extractLoopFD(io, gpa),
        .events = posix.POLL.IN,
        .revents = 0,
    };

    while (!quitt) {
        const events = posix.system.poll(@ptrCast(&pfd), 1, -1);
        if (events < 0) {
            break;
        } else if (events == 0) {
            continue;
        }

        if (pfd.revents & posix.POLL.HUP != 0) {
            break;
        }

        if (pfd.revents & posix.POLL.IN == 0) {
            continue;
        }

        try sock.dispatchEvents(io, gpa, false);
    }
}

pub fn main(init: std.process.Init) !void {
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
        try runClient(init.io, init.gpa, sock_fds[c]);
    } else {
        _ = posix.system.close(sock_fds[c]);
        try runServer(init.io, init.gpa, sock_fds[s]);
    }
}
