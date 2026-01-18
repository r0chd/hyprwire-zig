const std = @import("std");
const hw = @import("hyprwire");
const client = @import("test_protocol_v1-client.zig");
const spec = @import("test_protocol_v1-spec.zig");

const posix = std.posix;
const fmt = std.fmt;

const ProtocolClientImplementation = hw.types.client_impl.ProtocolClientImplementation;

const TEST_PROTOCOL_VERSION: u32 = 1;

pub fn main() !void {
    // var gpa: std.heap.DebugAllocator(.{}) = .init;
    // const alloc = gpa.allocator();
    // defer {
    //     const deinit_status = gpa.deinit();
    //     if (deinit_status == .leak) @panic("TEST FAIL");
    // }
    const alloc = std.heap.c_allocator;

    const xdg_runtime_dir = posix.getenv("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntimeDir;
    const socket_path = try fmt.allocPrintSentinel(alloc, "{s}/test-hw.sock", .{xdg_runtime_dir}, 0);
    defer alloc.free(socket_path);

    const socket = try hw.ClientSocket.open(alloc, .{ .path = socket_path });
    defer socket.deinit(alloc);

    var impl = client.TestProtocolV1Impl.init(1);
    try socket.addImplementation(alloc, ProtocolClientImplementation.from(&impl));

    try socket.waitForHandshake(alloc);

    var protocol = impl.protocol();
    const SPEC = socket.getSpec(protocol.vtable.specName(protocol.ptr)) orelse {
        std.debug.print("err: test protocol unsupported\n", .{});
        std.process.exit(1);
    };

    std.debug.print("test protocol supported at version {}. Binding.\n", .{SPEC.vtable.specVer(SPEC.ptr)});

    const obj = try socket.bindProtocol(alloc, protocol, TEST_PROTOCOL_VERSION);
    var manager = client.MyManagerV1Object.init(obj);

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
    manager.setSendMessage(&message);

    try socket.roundtrip(alloc);

    var object = client.MyObjectV1Object.init(manager.sendMakeObject(alloc).?);
    object.setSendMessage(&messageOnObject);
    try object.sendSendMessage(alloc, "Hello on object");
    try object.sendSendEnum(alloc, spec.TestProtocolV1MyEnum.world);

    std.debug.print("Sent hello!\n", .{});

    while (socket.dispatchEvents(alloc, true)) {} else |_| {}
}

fn message(self: *client.MyManagerV1Object, msg: [:0]const u8) void {
    _ = self;
    std.debug.print("Server says {s}\n", .{msg});
}

fn messageOnObject(self: *client.MyObjectV1Object, msg: [:0]const u8) void {
    _ = self;
    std.debug.print("Server says on object {s}\n", .{msg});
}
