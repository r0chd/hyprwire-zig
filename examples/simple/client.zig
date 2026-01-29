const std = @import("std");
const posix = std.posix;
const fmt = std.fmt;
const mem = std.mem;
const Io = std.Io;

const hw = @import("hyprwire");
const types = hw.types;
const test_protocol = hw.proto.test_protocol_v1.client;

const TEST_PROTOCOL_VERSION: u32 = 1;

const Client = struct {
    const Self = @This();

    pub fn myManagerV1Listener(self: *Self, alloc: mem.Allocator, event: test_protocol.MyManagerV1Object.Event) void {
        _ = alloc;
        _ = self;
        switch (event) {
            .send_message => |message| {
                std.debug.print("Server says {s}\n", .{message.message});
            },
            .recv_message_array_uint => |message| {
                std.debug.print("Server sent uint array {any}\n", .{message.message});
            },
        }
    }

    pub fn myObjectV1Listener(self: *Self, alloc: mem.Allocator, event: test_protocol.MyObjectV1Object.Event) void {
        _ = alloc;
        _ = self;
        switch (event) {
            .send_message => |message| {
                std.debug.print("Server says on object {s}\n", .{message.message});
            },
        }
    }
};

fn socketPath(alloc: mem.Allocator, environ: *std.process.Environ.Map) ![:0]u8 {
    const runtime_dir = environ.get("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntimeDir;
    return try fmt.allocPrintSentinel(alloc, "{s}/test-hw.sock", .{runtime_dir}, 0);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const socket_path = try socketPath(gpa, init.environ_map);
    defer gpa.free(socket_path);

    const socket = try hw.ClientSocket.open(io, gpa, .{ .path = socket_path });
    defer socket.deinit(io, gpa);

    var impl = test_protocol.TestProtocolV1Impl.init(1);
    try socket.addImplementation(gpa, types.client.ProtocolImplementation.from(&impl));

    try socket.waitForHandshake(io, gpa);

    var protocol = impl.protocol();
    const SPEC = socket.getSpec(protocol.vtable.specName(protocol.ptr)) orelse {
        std.debug.print("err: test protocol unsupported\n", .{});
        std.process.exit(1);
    };

    std.debug.print("test protocol supported at version {}. Binding.\n", .{SPEC.vtable.specVer(SPEC.ptr)});

    var client = Client{};

    var obj = try socket.bindProtocol(io, gpa, protocol, TEST_PROTOCOL_VERSION);
    defer obj.deinit(gpa);
    var manager = try test_protocol.MyManagerV1Object.init(
        gpa,
        test_protocol.MyManagerV1Object.Listener.from(&client),
        &types.Object.from(obj),
    );
    defer manager.deinit(gpa);

    std.debug.print("Bound!\n", .{});

    var pipes = try Io.Threaded.pipe2(.{});
    defer {
        _ = posix.system.close(pipes[0]);
        _ = posix.system.close(pipes[1]);
    }

    var out: Io.File = .{ .handle = pipes[1] };
    var buffer: [5]u8 = undefined;
    var writer = out.writer(io, &buffer);
    var iowriter = &writer.interface;
    try iowriter.writeAll("pipe!");
    try iowriter.flush();

    std.debug.print("Will send fd {}\n", .{pipes[0]});

    try manager.sendSendMessage(io, gpa, "Hello!");
    try manager.sendSendMessageFd(io, gpa, pipes[0]);
    try manager.sendSendMessageArrayFd(io, gpa, &.{pipes[0]});
    try manager.sendSendMessageArray(io, gpa, &.{ "Hello", "via", "array!" });
    try manager.sendSendMessageArray(io, gpa, &.{});
    try manager.sendSendMessageArrayUint(io, gpa, &.{ 69, 420, 2137 });

    try socket.roundtrip(io, gpa);

    var object_arg = manager.sendMakeObject(io, gpa).?;
    defer object_arg.vtable.deinit(object_arg.ptr, gpa);
    var object = try test_protocol.MyObjectV1Object.init(gpa, test_protocol.MyObjectV1Object.Listener.from(&client), &object_arg);
    defer object.deinit(gpa);

    try object.sendSendMessage(io, gpa, "Hello on object");
    try object.sendSendEnum(io, gpa, .world);

    std.debug.print("Sent hello!\n", .{});

    while (socket.dispatchEvents(io, gpa, true)) {} else |_| {}
}

test {
    std.testing.refAllDecls(@This());
}
