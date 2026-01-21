const std = @import("std");
const hw = @import("hyprwire");
const protocol_server = @import("test_protocol_v1-server.zig");
const protocol_spec = @import("test_protocol_v1-spec.zig");

const mem = std.mem;
const posix = std.posix;
const fmt = std.fmt;

var manager: *protocol_server.MyManagerV1Object = undefined;

fn bindFn(obj: *hw.types.Object, gpa: mem.Allocator) void {
    std.debug.print("Object bound XD\n", .{});

    manager = protocol_server.MyManagerV1Object.init(gpa, obj) catch return;

    manager.sendSendMessage(gpa, "Hello object") catch {};
    manager.setSendMessage(sendMessage);
    manager.setSendMessageFd(sendMessageFd);
    manager.setSendMessageArray(sendMessageArray);
    manager.setSendMessageArrayUint(sendMessageArrayUint);
    manager.setMakeObject(sendMakeObject);
    manager.setOnDeinit(onDeinit);
}

fn sendMessage(msg: [*:0]const u8) void {
    std.debug.print("Recvd message: {s}\n", .{msg});
}

fn sendMessageFd(fd: i32) void {
    var buf: [5]u8 = undefined;
    _ = posix.read(fd, &buf) catch {};
    std.debug.print("Recvd fd {} with data: {s}\n", .{ fd, buf });
}

fn sendMessageArray(data: [*][*:0]const u8) void {
    _ = data;
}

fn sendMessageArrayUint(data: [*]u32) void {
    _ = data;
}

fn sendMakeObject(data: u32) void {
    _ = data;
}

fn onDeinit() void {}

pub fn main() !void {
    // var gpa: std.heap.DebugAllocator(.{}) = .init;
    // const alloc = gpa.allocator();
    // defer {
    //     const deinit_status = gpa.deinit();
    //     if (deinit_status == .leak) @panic("LEAK DETECTED");
    // }
    const alloc = std.heap.c_allocator;

    const xdg_runtime_dir = posix.getenv("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntimeDir;
    const socket_path_buf = try fmt.allocPrintSentinel(alloc, "{s}/test-hw.sock", .{xdg_runtime_dir}, 0);
    defer alloc.free(socket_path_buf);

    var socket = try hw.ServerSocket.open(alloc, socket_path_buf);
    defer socket.deinit(alloc);

    const spec = protocol_server.TestProtocolV1Impl.init(1, bindFn);
    const pro = hw.types.server_impl.ProtocolServerImplementation.from(&spec);
    try socket.addImplementation(alloc, pro);

    while (socket.dispatchEvents(alloc, true) catch false) {}
}
