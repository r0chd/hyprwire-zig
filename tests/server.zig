const std = @import("std");
const hw = @import("hyprwire");

const posix = std.posix;
const fmt = std.fmt;

// const impl = hw.types.ProtocolServerImplementation{
//     .implementations = &.{},
// };
// const impl_ptr = &impl;

var quitt: bool = false;

fn sigHandler(sig: i32, info: *const posix.siginfo_t, ctx_ptr: ?*anyopaque) callconv(.c) void {
    _ = sig;
    _ = info;
    _ = ctx_ptr;
    quitt = true;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const alloc = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("TEST FAIL");
    }

    const sa = posix.Sigaction{
        .handler = .{ .sigaction = sigHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };

    posix.sigaction(std.c.SIG.INT, &sa, null);
    posix.sigaction(std.c.SIG.TERM, &sa, null);

    const xdg_runtime_dir = posix.getenv("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntimeDir;
    const socket_path_buf = try fmt.allocPrintSentinel(alloc, "{s}/test-hw.sock", .{xdg_runtime_dir}, 0);
    defer alloc.free(socket_path_buf);
    var socket = (try hw.ServerSocket.open(alloc, socket_path_buf)).?;
    defer socket.deinit(alloc);

    // try socket.addImplementation(alloc, impl_ptr);

    while (!quitt and socket.dispatchEvents(alloc, true)) {}
}
