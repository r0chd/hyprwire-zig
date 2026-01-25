const std = @import("std");
const posix = std.posix;
const fmt = std.fmt;
const mem = std.mem;

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

fn socketPath(alloc: mem.Allocator) ![:0]u8 {
    const runtime_dir = posix.getenv("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntimeDir;
    return try fmt.allocPrintSentinel(alloc, "{s}/test-hw.sock", .{runtime_dir}, 0);
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const alloc = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("TEST FAIL");
    }

    const socket_path = try socketPath(alloc);
    defer alloc.free(socket_path);

    const socket = try hw.ClientSocket.open(alloc, .{ .path = socket_path });
    defer socket.deinit(alloc);

    var impl = test_protocol.TestProtocolV1Impl.init(1);
    try socket.addImplementation(alloc, types.client.ProtocolImplementation.from(&impl));

    try socket.waitForHandshake(alloc);

    var protocol = impl.protocol();
    const SPEC = socket.getSpec(protocol.vtable.specName(protocol.ptr)) orelse {
        std.debug.print("err: test protocol unsupported\n", .{});
        std.process.exit(1);
    };

    std.debug.print("test protocol supported at version {}. Binding.\n", .{SPEC.vtable.specVer(SPEC.ptr)});

    var client = Client{};

    var obj = try socket.bindProtocol(alloc, protocol, TEST_PROTOCOL_VERSION);
    defer obj.deinit(alloc);
    var manager = try test_protocol.MyManagerV1Object.init(
        alloc,
        test_protocol.MyManagerV1Object.Listener.from(&client),
        &types.Object.from(obj),
    );
    defer manager.deinit(alloc);

    std.debug.print("Bound!\n", .{});

    const pipes = try posix.pipe();
    defer {
        posix.close(pipes[0]);
        posix.close(pipes[1]);
    }

    _ = try posix.write(pipes[1], "pipe!");

    std.debug.print("Will send fd {}\n", .{pipes[0]});

    try manager.sendSendMessage(alloc, "Hello!");
    try manager.sendSendMessageFd(alloc, pipes[0]);
    try manager.sendSendMessageArray(alloc, &.{ "Hello", "via", "array!" });
    try manager.sendSendMessageArray(alloc, &.{});
    try manager.sendSendMessageArrayUint(alloc, &.{ 69, 420, 2137 });

    try socket.roundtrip(alloc);

    var object_arg = manager.sendMakeObject(alloc).?;
    defer object_arg.vtable.deinit(object_arg.ptr, alloc);
    var object = try test_protocol.MyObjectV1Object.init(alloc, test_protocol.MyObjectV1Object.Listener.from(&client), &object_arg);
    defer object.deinit(alloc);

    try object.sendSendMessage(alloc, "Hello on object");
    try object.sendSendEnum(alloc, .world);

    std.debug.print("Sent hello!\n", .{});

    while (socket.dispatchEvents(alloc, true)) {} else |_| {}
}
