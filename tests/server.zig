const std = @import("std");
const hw = @import("hyprwire");

const posix = std.posix;
const fmt = std.fmt;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const alloc = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("TEST FAIL");
    }

    const xdg_runtime_dir = posix.getenv("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntimeDir;
    const socket_path_buf = try fmt.allocPrintSentinel(alloc, "{s}/test-hw.sock", .{xdg_runtime_dir}, 0);
    defer alloc.free(socket_path_buf);
    var socket = try hw.ServerSocket.open(alloc, socket_path_buf);
    defer socket.deinit(alloc);

    while (socket.dispatchEvents(alloc, true)) {} else |_| {}
}
