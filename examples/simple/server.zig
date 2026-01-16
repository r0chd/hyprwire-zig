const std = @import("std");
const hw = @import("hyprwire");
const protocol_server = @import("test_protocol_v1-server.zig");
const protocol_spec = @import("test_protocol_v1-spec.zig");

const posix = std.posix;
const fmt = std.fmt;

fn bindFn(obj: hw.types.Object) void {
    _ = obj;
    std.debug.print("Object bound XD\n", .{});
}

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

    var socket = try hw.ServerSocket.open(alloc, socket_path_buf);
    defer socket.deinit(alloc);

    const spec = protocol_server.TestProtocolV1Impl.init(1, &bindFn);

    const pro = hw.types.server_impl.ProtocolServerImplementation.from(&spec);
    try socket.addImplementation(alloc, pro);

    while (socket.dispatchEvents(alloc, true)) {} else |_| {}
}
